-- Repeat-purchase rate and second-order AOV for new buyers acquired via a
-- "first local sale" (artist's first sale, delivery country = shipment country),
-- comparing customers acquired pre vs post the 2024-09-23 free-shipping policy.
--
-- Fixed 180-day observation window: only customers whose first order happened
-- at least 180 days before the data cutoff (2026-07-01) are included, so both
-- cohorts have had an equal amount of time to come back. Without this, the
-- post-policy cohort would look artificially "less loyal" simply because many
-- of them haven't had 180 days yet.
--
-- ROOT CAUSE OF THE ORIGINAL BUG (confirmed against live data, not just the SQL text):
-- all_sales.customer_order_number is NOT a reliable, gap-free, globally-sequential
-- "this customer's Nth order ever" counter:
--   - Some customers have MULTIPLE distinct orders all stuck at the same order
--     number (e.g. customer_id 201619 has 18 separate orders across 13 months,
--     every single one tagged customer_order_number = 1 -- it never increments).
--     313 of ~36k (customer_id, customer_order_number) pairs exhibit this tie.
--   - all_sales is line-item grain, not order grain: 91,685 sale rows collapse to
--     only 71,191 distinct order_id values, so a multi-item order has one row per
--     artwork, all sharing the same order_id/customer_order_number/paid_at, but
--     each with its OWN (partial) amount_eur_paid. Filtering "customer_order_number = 2"
--     directly therefore fans out on any customer whose 2nd order had 2+ items,
--     and mixes up per-line amounts with true order value (AOV).
--   - Combined, these two defects caused a real, observed LEFT JOIN fan-out
--     (raw joined row count roughly 2x the distinct-customer count) and produced
--     an impossible negative avg_days_to_repeat (-23.9 days) for the post cohort
--     in the original query -- i.e. some customers' "second order" appeared to
--     predate their "first order", which is the concrete symptom of "implausible
--     numbers" reported.
--
-- FIX: don't trust the stored customer_order_number. Rebuild order-level rows
-- (one per real order_id, amount = SUM across its line items) and recompute a
-- true, tie-free order number via ROW_NUMBER() partitioned by customer_id and
-- ordered by paid_at/order_id. Also explicitly drop customer_id IS NULL rows
-- (over half of the raw "first local sale" line items matching artist_order_number = 1
-- had no customer_id at all -- guest/unlinked checkouts that can never be observed
-- repeating anyway, since NULL never joins to NULL).
--
-- Other checks performed and ruled out as NOT the cause:
--   - paid_at is a DATETIME (not TIMESTAMP), so there is no UTC/local-timezone
--     ambiguity in comparing DATE(paid_at) to '2024-09-23'.
--   - artist_order_number has an ~12-13% NULL rate but is stable across years and
--     its ties at value 1 all correspond to the SAME order_id (legitimate same-order,
--     multi-artwork purchases) -- it behaves correctly as an order-level indicator,
--     unlike customer_order_number.
--   - all_artworks JOIN all_artists is a clean 1:1 join (no fan-out).
--
-- DECLARE statements only work in BigQuery "script" contexts (console script mode,
-- bq query run as a script, scripted scheduled queries) -- they fail in a saved
-- view, a single-statement scheduled query, or a plain jobs.query API call.
-- Converted to a literal `params` CTE below so this runs anywhere.

WITH params AS (
  SELECT
    180 AS observation_window_days,
    DATE '2026-07-01' AS data_cutoff
),

first_sale_local_filter AS (
  SELECT
    artwork_id,
    artist_id,
    country_shipment_from
  FROM `singulart-data.connected_sheets.all_artworks` a_a
  INNER JOIN `singulart-data.connected_sheets.all_artists` USING(artist_id)
),

-- Collapse line items to one row per real order and recompute a trustworthy
-- order number ourselves -- see the root-cause note above.
order_totals AS (
  SELECT
    customer_id,
    order_id,
    MIN(paid_at) AS order_paid_at,
    SUM(amount_eur_paid) AS order_amount
  FROM `singulart-data.connected_sheets.all_sales`
  WHERE customer_id IS NOT NULL
  GROUP BY 1, 2
),

order_true_rank AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_paid_at, order_id) AS true_customer_order_number
  FROM order_totals
),

-- The acquisition event (artist's first sale, local) is inherently a line-item
-- concept, so identify qualifying orders at that grain, then dedupe to one row
-- per order (rare edge case: an order containing 2+ qualifying lines from
-- different artists -- tie broken deterministically by artwork_id).
acquisition_lines AS (
  SELECT
    a_s.customer_id,
    a_s.order_id,
    fslf.country_shipment_from,
    ROW_NUMBER() OVER (PARTITION BY a_s.customer_id, a_s.order_id ORDER BY a_s.artwork_id) AS rn
  FROM `singulart-data.connected_sheets.all_sales` a_s
  INNER JOIN first_sale_local_filter fslf
    ON fslf.artwork_id = a_s.artwork_id
    AND fslf.country_shipment_from = a_s.delivery_country
  CROSS JOIN params
  WHERE a_s.artist_order_number = 1        -- artist's first sale
    AND a_s.customer_id IS NOT NULL
    AND a_s.paid_at >= '2023-05-03'
    AND a_s.paid_at < params.data_cutoff
),

acquisition_orders AS (
  SELECT customer_id, order_id, country_shipment_from
  FROM acquisition_lines
  WHERE rn = 1
),

-- The acquisition event: a customer's true first-ever order, which also happens
-- to be the artist's first sale, and is a local sale (shipment = delivery country).
first_local_sale_new_buyers AS (
  SELECT
    ot.customer_id,
    ao.country_shipment_from,
    DATE(ot.order_paid_at) AS first_order_date,
    ot.order_amount AS first_order_amount,
    CASE
      WHEN DATE(ot.order_paid_at) < '2024-09-23' THEN 'pre_free_shipping_fees_for_local_sales'
      ELSE 'post_free_shipping_fees_for_local_sales'
    END AS cohort_tag
  FROM order_true_rank ot
  INNER JOIN acquisition_orders ao ON ao.customer_id = ot.customer_id AND ao.order_id = ot.order_id
  CROSS JOIN params
  WHERE ot.true_customer_order_number = 1
    -- equal-runway filter: exclude anyone too recent to have had a fair shot at repeating
    AND DATE_DIFF(params.data_cutoff, DATE(ot.order_paid_at), DAY) >= params.observation_window_days
),

-- Each customer's true next order, anywhere on the platform (not restricted to
-- local sales or first-artist-sales) -- this is the "did they come back at all"
-- signal. Guaranteed at most one row per customer_id, so the join below cannot fan out.
second_order AS (
  SELECT
    customer_id,
    order_paid_at AS second_order_paid_at,
    order_amount AS second_order_amount
  FROM order_true_rank
  WHERE true_customer_order_number = 2
),

cohort_with_repeat AS (
  SELECT
    f.cohort_tag,
    f.country_shipment_from,
    f.customer_id,
    f.first_order_amount,
    s.second_order_amount,
    DATE_DIFF(DATE(s.second_order_paid_at), f.first_order_date, DAY) AS days_to_repeat
  FROM first_local_sale_new_buyers f
  LEFT JOIN second_order s ON s.customer_id = f.customer_id
)

SELECT
  cohort_tag,
  COUNT(DISTINCT customer_id) AS nb_new_buyers_eligible,
  COUNT(DISTINCT IF(days_to_repeat IS NOT NULL AND days_to_repeat <= (SELECT observation_window_days FROM params), customer_id, NULL)) AS nb_repeat_within_window,
  SAFE_DIVIDE(
    COUNT(DISTINCT IF(days_to_repeat IS NOT NULL AND days_to_repeat <= (SELECT observation_window_days FROM params), customer_id, NULL)),
    COUNT(DISTINCT customer_id)
  ) AS repeat_purchase_rate,
  AVG(first_order_amount) AS avg_first_order_aov,
  AVG(IF(days_to_repeat IS NOT NULL AND days_to_repeat <= (SELECT observation_window_days FROM params), second_order_amount, NULL)) AS avg_second_order_aov,
  AVG(IF(days_to_repeat IS NOT NULL AND days_to_repeat <= (SELECT observation_window_days FROM params), days_to_repeat, NULL)) AS avg_days_to_repeat
FROM cohort_with_repeat
GROUP BY 1
ORDER BY 1 DESC;

-- Optional follow-up cut: same query grouped by (cohort_tag, country_shipment_from)
-- to see if the repeat-rate/second-order-AOV story differs for DE/FR (biggest AOV
-- drop) vs ES/GB (AOV held up or rose) -- swap the final GROUP BY to (1, 2) and
-- add country_shipment_from to the SELECT to get that split.
