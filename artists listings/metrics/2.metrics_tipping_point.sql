WITH
buyers_list AS (
  SELECT visitor_id
  FROM `singulart-data.views.visitor_attribution`
  WHERE first_order_at IS NOT NULL
),

-- Sold artworks: sold in L12M, online for at least 90 days before the sale
-- (ensures every artwork in the sold group had a full 90-day window to accumulate engagement)
sold_artworks AS (
  SELECT
    aa.artwork_id,
    DATE(aa.artwork_online_at) AS online_date,
    DATE(a_s.paid_at)          AS paid_date,
    'sold'                     AS status
  FROM `singulart-data.connected_sheets.all_artworks` aa
  INNER JOIN `singulart-data.connected_sheets.all_sales` a_s ON a_s.artwork_id = aa.artwork_id
  WHERE a_s.paid_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)
    AND aa.artwork_online_at < a_s.paid_at
    AND DATE(aa.artwork_online_at) >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
    AND DATE_DIFF(DATE(a_s.paid_at), DATE(aa.artwork_online_at), DAY) >= 90
),

-- Available artworks: currently online, went online 90+ days ago, never sold
-- Limited to L24M online date to keep the cohort comparable to sold artworks
unsold_artworks AS (
  SELECT
    aa.artwork_id,
    DATE(aa.artwork_online_at) AS online_date,
    CAST(NULL AS DATE)         AS paid_date,
    'available'                AS status
  FROM `singulart-data.connected_sheets.all_artworks` aa
  LEFT JOIN `singulart-data.connected_sheets.all_sales` a_s ON a_s.artwork_id = aa.artwork_id
  WHERE aa.is_hiearchically_online = 1 and paid_at is null
    AND aa.artwork_online_at IS NOT NULL
    AND DATE_DIFF(CURRENT_DATE, DATE(aa.artwork_online_at), DAY) >= 90
    AND DATE(aa.artwork_online_at) >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
    AND a_s.artwork_id IS NULL
),

artwork_cohort AS (
  SELECT * FROM sold_artworks
  UNION ALL
  SELECT * FROM unsold_artworks
),

raw_events AS (
  SELECT
    'view'                        AS metric_type,
    SAFE_CAST(i.item_id AS INT64) AS artwork_id,
    ge.event_date                 AS event_date
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN buyers_list bl ON bl.visitor_id = ge.visitor_id
  WHERE ge.event_name = 'view_item_list'
    AND i.item_list_name in ('ap','ap-l')
    AND ge.event_date >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)

  UNION ALL

  SELECT
    'click',
    SAFE_CAST(pv.object_id AS INT64),
    DATE(pv.created_at)
  FROM `singulart-data.views.all_pageviews` pv
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = pv.session_id
  INNER JOIN buyers_list bl ON bl.visitor_id = s.visitor_id
  WHERE pv.tpl = 'artwork'
    AND pv.created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)

  UNION ALL

  SELECT
    'wishlist',
    wishlist.artwork_id,
    DATE(wishlist.wishlist_created_at)
  FROM `singulart-data.connected_sheets.all_wishlists` wishlist
  INNER JOIN buyers_list bl ON bl.visitor_id = wishlist.visitor_id
  WHERE wishlist.wishlist_created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)

  UNION ALL

  SELECT
    'add_to_cart',
    scl.artwork_id,
    DATE(sc.created_at)
  FROM `singulart-db-to-bigquery.singulartdb.sgt_carts_lines` scl
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_carts` sc ON sc.id = scl.cart_id
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = sc.browsing_session_id
  INNER JOIN buyers_list bl ON bl.visitor_id = s.visitor_id
  WHERE sc.created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)
),

-- Join events to cohort, keep only first-90-days events, and pre-sale only
cohort_events AS (
  SELECT
    ac.artwork_id,
    ac.status,
    re.metric_type,
    DATE_DIFF(re.event_date, ac.online_date, DAY) AS days_since_online
  FROM artwork_cohort ac
  INNER JOIN raw_events re ON re.artwork_id = ac.artwork_id
  WHERE re.event_date >= ac.online_date
    AND re.event_date <= DATE_ADD(ac.online_date, INTERVAL 90 DAY)
    AND (ac.paid_date IS NULL OR re.event_date < ac.paid_date)
),

-- Cumulative event counts per artwork per metric at each day threshold
event_counts AS (
  SELECT
    artwork_id,
    metric_type,
    COUNTIF(days_since_online <=  7) AS events_d07,
    COUNTIF(days_since_online <= 14) AS events_d14,
    COUNTIF(days_since_online <= 30) AS events_d30,
    COUNTIF(days_since_online <= 60) AS events_d60,
    COUNTIF(days_since_online <= 90) AS events_d90
  FROM cohort_events
  GROUP BY 1, 2
),

-- One row per artwork × metric type, including artworks with zero engagement
per_artwork AS (
  SELECT
    ac.artwork_id,
    ac.status,
    mt                         AS metric_type,
    COALESCE(ec.events_d07, 0) AS events_d07,
    COALESCE(ec.events_d14, 0) AS events_d14,
    COALESCE(ec.events_d30, 0) AS events_d30,
    COALESCE(ec.events_d60, 0) AS events_d60,
    COALESCE(ec.events_d90, 0) AS events_d90
  FROM artwork_cohort ac
  CROSS JOIN UNNEST(['view', 'click', 'wishlist', 'add_to_cart']) AS mt
  LEFT JOIN event_counts ec ON ec.artwork_id = ac.artwork_id AND ec.metric_type = mt
)

SELECT
  status,
  metric_type,
  day_threshold,
  COUNT(*)                                             AS nb_artworks,
  ROUND(AVG(nb_events), 4)                            AS avg_events_per_artwork,
  ROUND(APPROX_QUANTILES(nb_events, 2)[OFFSET(1)], 2) AS median_events_per_artwork,
  ROUND(COUNTIF(nb_events > 0) / COUNT(*), 4)         AS pct_with_any_event
FROM (
  SELECT status, metric_type, '1. Day 07' AS day_threshold, events_d07 AS nb_events FROM per_artwork
  UNION ALL
  SELECT status, metric_type, '2. Day 14',                  events_d14             FROM per_artwork
  UNION ALL
  SELECT status, metric_type, '3. Day 30',                  events_d30             FROM per_artwork
  UNION ALL
  SELECT status, metric_type, '4. Day 60',                  events_d60             FROM per_artwork
  UNION ALL
  SELECT status, metric_type, '5. Day 90',                  events_d90             FROM per_artwork
)
GROUP BY 1, 2, 3
ORDER BY 2, 1, 3
