WITH

sellers AS (
  SELECT DISTINCT artist_id
  FROM `singulart-data.connected_sheets.all_sales`
  WHERE artwork_id IS NOT NULL
),

artists_plans AS (
  SELECT
    ap.stripe_subscription_id,
    ap.stripe_customer_id,
    ap.artist_id,
    ap.level,
    ap.frequency,
    ap.created_at,
    row_number() OVER (PARTITION BY ap.artist_id ORDER BY ap.created_at ASC) AS subscription_asc,
    CASE WHEN s.artist_id IS NOT NULL THEN 'Seller' ELSE 'Non-seller' END AS seller_type,
    -- deduplicate to one row per subscription_id to prevent fan-out on join
    row_number() OVER (PARTITION BY ap.stripe_subscription_id ORDER BY ap.created_at DESC) AS rn_sub,
    -- deduplicate to most recent plan per customer for fallback join
    row_number() OVER (PARTITION BY ap.stripe_customer_id ORDER BY ap.created_at DESC) AS rn_cust
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans` ap
  LEFT JOIN sellers s ON s.artist_id = ap.artist_id
),

-- one row per subscription_id (primary join key)
artists_plans_by_subscription AS (
  SELECT * FROM artists_plans
  WHERE rn_sub = 1
),

-- one row per customer_id (fallback when subscription_id has no match)
artists_plans_by_customer AS (
  SELECT * FROM artists_plans
  WHERE rn_cust = 1
),

ts_grouped_sub_item_events AS (
  SELECT
    local_event_timestamp,
    currency,
    customer_id,
    subscription_id,
    sum(mrr_change) AS mrr_change
  FROM
    `singulart-data.stripe.subscription_item_change_events`
  GROUP BY
    1, 2, 3, 4
),
ts_grouped_sub_item_events_with_mrr AS (
  SELECT
    *,
    DATE_TRUNC(DATE(local_event_timestamp), day) AS local_event_date,
    -- Stripe defines an "active subscriber" as a customer with non-zero MRR.
    -- Therefore instead of summing up event_type to get subscription count (and its diff),
    -- We count the amount of revenue on each customer instead and later check its movement from / to zero
    SUM(mrr_change) OVER (
      PARTITION BY customer_id
      ORDER BY local_event_timestamp ASC
    ) AS mrr,
    -- We count the # of times MRR has actually changed, and use nullif to ignore events that do not impact MRR
    -- Otherwise we may confuse between new vs. reactivation
    COUNT(nullif(mrr_change, 0)) OVER (
      PARTITION BY customer_id
      ORDER BY local_event_timestamp ASC
    ) AS mrr_change_count
  FROM
    ts_grouped_sub_item_events
),
ts_grouped_sub_item_events_with_previous_mrr AS (
  SELECT
    *,
    COALESCE(
      LAST_VALUE(mrr IGNORE NULLS) OVER (
        PARTITION BY customer_id
        ORDER BY local_event_timestamp ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ),
      0
    ) AS previous_mrr
  FROM
    ts_grouped_sub_item_events_with_mrr
),
customer_events AS (
  SELECT
    *,
    CASE
      WHEN mrr = 0 AND previous_mrr > 0
      THEN 'ACTIVE_END'
      WHEN mrr > 0 AND previous_mrr = 0 AND mrr_change_count = 1
      THEN 'ACTIVE_START'
      WHEN mrr > 0 AND previous_mrr = 0 AND mrr_change_count > 1
      THEN 'REACTIVATE'
      WHEN mrr > previous_mrr
      THEN 'ACTIVE_UPGRADE'
      WHEN mrr < previous_mrr
      THEN 'ACTIVE_DOWNGRADE'
      ELSE NULL
    END AS cus_event_type
  FROM
    ts_grouped_sub_item_events_with_previous_mrr
),
date_grouped_customer_events AS (
  SELECT
    local_event_date,
    customer_events.currency,
    COALESCE(ap_sub.level, ap_cust.level, 'Unknown') AS level,
    CASE
      WHEN COALESCE(ap_sub.subscription_asc, ap_cust.subscription_asc) IS NULL THEN 'Unknown'
      WHEN COALESCE(ap_sub.subscription_asc, ap_cust.subscription_asc) = 1 THEN 'New'
      ELSE 'Winback'
    END AS artist_type,
    COALESCE(ap_sub.frequency, ap_cust.frequency, 'Unknown') AS frequency,
    COALESCE(ap_sub.seller_type, ap_cust.seller_type, 'Unknown') AS seller_type,
    SUM(mrr_change*cr.rate) AS mrr_change,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_START' THEN mrr_change*cr.rate
        ELSE 0
      END
    ) AS new_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'REACTIVATE' THEN mrr_change*cr.rate
        ELSE 0
      END
    ) AS reactivation_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_UPGRADE' THEN mrr_change*cr.rate
        ELSE 0
      END
    ) AS expansion_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_DOWNGRADE' THEN mrr_change*cr.rate
        ELSE 0
      END
    ) AS contraction_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_END' THEN mrr_change*cr.rate
        ELSE 0
      END
    ) AS churn_mrr
  FROM customer_events
  LEFT JOIN artists_plans_by_subscription ap_sub ON ap_sub.stripe_subscription_id = customer_events.subscription_id
  LEFT JOIN artists_plans_by_customer ap_cust ON ap_cust.stripe_customer_id = customer_events.customer_id
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies` sc ON UPPER(sc.currency) = UPPER(customer_events.currency)
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies_rates` cr ON cr.base_id = sc.id AND cr.target_id = 43
  GROUP BY
    1, 2, 3, 4, 5, 6
),
-- Raw daily totals per segment, only on dates with events
daily_metrics_raw AS (
  SELECT
    local_event_date AS local_date,
    level,
    artist_type,
    frequency,
    seller_type,
    SUM(mrr_change) AS mrr_change,
    SUM(new_mrr) AS new_mrr,
    SUM(reactivation_mrr) AS reactivation_mrr,
    SUM(expansion_mrr) AS expansion_mrr,
    SUM(contraction_mrr) AS contraction_mrr,
    SUM(churn_mrr) AS churn_mrr
  FROM
    date_grouped_customer_events
  GROUP BY
    1, 2, 3, 4, 5
),
-- All distinct segment combinations
segments AS (
  SELECT DISTINCT level, artist_type, frequency, seller_type
  FROM daily_metrics_raw
),
-- Continuous date range covering all event dates
date_spine AS (
  SELECT local_date
  FROM UNNEST(GENERATE_DATE_ARRAY(
    (SELECT MIN(local_date) FROM daily_metrics_raw),
    (SELECT MAX(local_date) FROM daily_metrics_raw)
  )) AS local_date
),
-- Every date × every segment, with 0 for days with no events
-- This ensures LAG(30) and ROWS BETWEEN always span exactly 30 calendar days
daily_metrics AS (
  SELECT
    ds.local_date,
    seg.level,
    seg.artist_type,
    seg.frequency,
    seg.seller_type,
    SUM(COALESCE(dm.mrr_change, 0)) OVER (
      PARTITION BY seg.level, seg.artist_type, seg.frequency, seg.seller_type
      ORDER BY ds.local_date ASC
    ) AS mrr,
    COALESCE(dm.mrr_change, 0) AS mrr_change,
    COALESCE(dm.new_mrr, 0) AS new_mrr,
    COALESCE(dm.reactivation_mrr, 0) AS reactivation_mrr,
    COALESCE(dm.expansion_mrr, 0) AS expansion_mrr,
    COALESCE(dm.contraction_mrr, 0) AS contraction_mrr,
    COALESCE(dm.churn_mrr, 0) AS churn_mrr
  FROM date_spine ds
  CROSS JOIN segments seg
  LEFT JOIN daily_metrics_raw dm
    ON dm.local_date = ds.local_date
    AND dm.level = seg.level
    AND dm.artist_type = seg.artist_type
    AND dm.frequency = seg.frequency
    AND dm.seller_type = seg.seller_type
),
daily_metrics_with_derived AS (
  SELECT
    *,
    COALESCE(
      LAG(mrr, 30) OVER (PARTITION BY level, artist_type, frequency, seller_type ORDER BY local_date),
      0
    ) AS previous_month_mrr
  FROM
    daily_metrics
),
daily_metrics_with_net AS (
  SELECT
    *,
    SUM(ABS(contraction_mrr + churn_mrr) - (expansion_mrr + reactivation_mrr)) OVER (
      PARTITION BY level, artist_type, frequency, seller_type
      ORDER BY local_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS net_mrr_churn
  FROM
    daily_metrics_with_derived
)
SELECT
  *,
  COALESCE(net_mrr_churn / NULLIF(previous_month_mrr, 0) * 100, 0) AS total
FROM
  daily_metrics_with_net
ORDER BY
  1 DESC
