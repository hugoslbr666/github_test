WITH
bv_per_artist AS (
  SELECT
    a_a.artist_id,
    SUM(amount_eur_paid) AS total_bv
  FROM `singulart-data.connected_sheets.all_artists` a_a
  LEFT JOIN `singulart-data.connected_sheets.all_sales` USING (artist_id)
  WHERE paid_at >= '2024-01-01'
  GROUP BY artist_id
),

with_cumulative AS (
  SELECT
    artist_id,
    total_bv,
    ROW_NUMBER() OVER (ORDER BY total_bv DESC) AS rank,
    ROUND(
      100 * SUM(total_bv) OVER (ORDER BY total_bv DESC)
      / SUM(total_bv) OVER (),
      1
    ) AS cumulative_pct
  FROM bv_per_artist
),

quartile_split AS (
  SELECT
    artist_id,
    total_bv,
    rank,
    cumulative_pct,
    CASE
      WHEN cumulative_pct <= 25 THEN '1. Top 25%'
      WHEN cumulative_pct <= 50 THEN '2. Top 25-50%'
      WHEN cumulative_pct <= 75 THEN '3. Top 50-75%'
      ELSE '4. Bottom 25%'
    END AS segment
  FROM with_cumulative
),

non_intra AS (
  SELECT
    COALESCE(qs.segment, '4. Bottom 25%') AS segment,
    COUNT(DISTINCT ge.ga_session_id) AS nb_ga_session_id,
    COUNT(DISTINCT IF(ge.session_engaged = 1, ge.ga_session_id, NULL)) AS nb_sessions_engaged,
    -- # events
    COUNT(DISTINCT IF(ge.event_name = "view_item_list", ge.new_eventId, NULL)) AS nb_view_item,
    COUNT(DISTINCT IF(ge.event_name = "select_item", ge.new_eventId, NULL)) AS nb_select_item,
    COUNT(DISTINCT IF(ge.event_name = "add_to_wishlist", ge.new_eventId, NULL)) AS nb_add_to_wishlist,
    COUNT(DISTINCT IF(ge.event_name = "add_to_cart", ge.new_eventId, NULL)) AS nb_add_to_cart,
    COUNT(DISTINCT IF(ge.event_name = "purchase", ge.new_eventId, NULL)) AS nb_purchase,
    -- # sessions
    COUNT(DISTINCT IF(ge.event_name = "view_item_list", ge.ga_session_id, NULL)) AS nb_sessions_view_item,
    COUNT(DISTINCT IF(ge.event_name = "select_item", ge.ga_session_id, NULL)) AS nb_sessions_select_item,
    COUNT(DISTINCT IF(ge.event_name = "add_to_wishlist", ge.ga_session_id, NULL)) AS nb_sessions_add_to_wishlist,
    COUNT(DISTINCT IF(ge.event_name = "add_to_cart", ge.ga_session_id, NULL)) AS nb_sessions_add_to_cart,
    COUNT(DISTINCT IF(ge.event_name = "purchase", ge.ga_session_id, NULL)) AS nb_sessions_purchase,
    -- BV estimate
    SUM(IF(ge.event_name = "purchase", ge.event_value_in_usd * scr.rate, 0)) AS bv_eur_estimate,
    COUNT(DISTINCT ge.visitor_id) AS nb_sg_visitor_id,
  FROM `singulart-data.ga_events.ga_events` ge, UNNEST(items) i
  INNER JOIN `singulart-data.views.visitor_attribution` va ON va.visitor_id = ge.visitor_id AND va.first_order_at IS NOT NULL
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies_rates` scr ON scr.base_id = 142 AND scr.target_id = 43
  LEFT JOIN quartile_split qs ON qs.artist_id = i.item_brand
  WHERE ge.event_date >= "2024-11-01"
AND ge.event_date < "2026-01-01"
AND ge.ga_session_id IS NOT NULL
AND NOT ((ge.event_date BETWEEN '2024-11-12' AND '2024-12-02')
OR (ge.event_date BETWEEN '2025-02-10' AND '2025-03-09')
OR (ge.event_date BETWEEN '2025-04-21' AND '2025-05-04')
OR (ge.event_date BETWEEN '2025-05-19' AND '2025-06-01')
OR (ge.event_date BETWEEN '2025-06-16' AND '2025-06-29')
OR (ge.event_date BETWEEN '2025-08-18' AND '2025-08-31')
OR (ge.event_date BETWEEN '2025-09-22' AND '2025-10-05')
OR (ge.event_date BETWEEN '2025-11-03' AND '2025-12-07'))
  GROUP BY ALL
)

SELECT *
FROM non_intra
