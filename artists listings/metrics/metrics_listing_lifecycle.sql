WITH
buyers_list AS (
  SELECT visitor_id
  FROM `singulart-data.views.visitor_attribution`
  WHERE first_order_at IS NOT NULL
),

sold_artworks AS (
  SELECT
    aa.artwork_id,
    aa.artist_id,
    DATE(aa.artwork_online_at)  AS online_date,
    DATE(a_s.paid_at)           AS paid_date,
    DATE_DIFF(DATE(a_s.paid_at), DATE(aa.artwork_online_at), DAY) AS listing_days
  FROM `singulart-data.connected_sheets.all_artworks` aa
  INNER JOIN `singulart-data.connected_sheets.all_sales` a_s ON a_s.artwork_id = aa.artwork_id
  WHERE a_s.paid_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)
    AND aa.artwork_online_at IS NOT NULL
    AND DATE_DIFF(DATE(a_s.paid_at), DATE(aa.artwork_online_at), DAY) > 0  -- exclude same-day sales
),

-- all engagement events for sold artworks, labelled by metric type
events AS (
  SELECT
    'view'        AS metric_type,
    aa.artwork_id,
    ge.event_date AS event_date
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN `singulart-data.connected_sheets.all_artworks` aa ON aa.artwork_id = SAFE_CAST(i.item_id AS INT64)
  INNER JOIN buyers_list bl ON bl.visitor_id = ge.visitor_id
  WHERE ge.event_name = 'view_item_list'
    AND ge.event_date >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)

  UNION ALL

  SELECT
    'click'       AS metric_type,
    SAFE_CAST(pv.object_id AS INT64) AS artwork_id,
    DATE(pv.created_at)              AS event_date
  FROM `singulart-data.views.all_pageviews` pv
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = pv.session_id
  INNER JOIN buyers_list bl ON bl.visitor_id = s.visitor_id
  WHERE pv.tpl = 'artwork'
    AND pv.created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)

  UNION ALL

  SELECT
    'wishlist'    AS metric_type,
    wishlist.artwork_id,
    DATE(wishlist.wishlist_created_at) AS event_date
  FROM `singulart-data.connected_sheets.all_wishlists` wishlist
  INNER JOIN buyers_list bl ON bl.visitor_id = wishlist.visitor_id
  WHERE wishlist.wishlist_created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)

  UNION ALL

  SELECT
    'add_to_cart' AS metric_type,
    scl.artwork_id,
    DATE(sc.created_at) AS event_date
  FROM `singulart-db-to-bigquery.singulartdb.sgt_carts_lines` scl
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_carts` sc ON sc.id = scl.cart_id
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = sc.browsing_session_id
  INNER JOIN buyers_list bl ON bl.visitor_id = s.visitor_id
  WHERE sc.created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)
),

lifecycle_events AS (
  SELECT
    e.metric_type,
    e.artwork_id,
    sa.listing_days,
    DATE_DIFF(e.event_date, sa.online_date, DAY)                                     AS days_since_online,
    FLOOR(100.0 * DATE_DIFF(e.event_date, sa.online_date, DAY) / sa.listing_days)    AS lifecycle_pct
  FROM events e
  INNER JOIN sold_artworks sa ON sa.artwork_id = e.artwork_id
  -- only count events that happened while the artwork was listed (before sale)
  WHERE e.event_date >= sa.online_date
    AND e.event_date <  sa.paid_date
),

nb_artworks AS (
  SELECT COUNT(DISTINCT artwork_id) AS total_sold_artworks
  FROM sold_artworks
)

SELECT
  le.metric_type,

  -- absolute time bucket
  CASE
    WHEN days_since_online <=  7 THEN '1. Days 01-07'
    WHEN days_since_online <= 14 THEN '2. Days 08-14'
    WHEN days_since_online <= 30 THEN '3. Days 15-30'
    WHEN days_since_online <= 60 THEN '4. Days 31-60'
    WHEN days_since_online <= 90 THEN '5. Days 61-90'
    ELSE                              '6. Days 91+'
  END AS days_bucket,

  -- relative lifecycle bucket (deciles)
  CASE
    WHEN lifecycle_pct <  10 THEN '01. 0-10%'
    WHEN lifecycle_pct <  20 THEN '02. 10-20%'
    WHEN lifecycle_pct <  30 THEN '03. 20-30%'
    WHEN lifecycle_pct <  40 THEN '04. 30-40%'
    WHEN lifecycle_pct <  50 THEN '05. 40-50%'
    WHEN lifecycle_pct <  60 THEN '06. 50-60%'
    WHEN lifecycle_pct <  70 THEN '07. 60-70%'
    WHEN lifecycle_pct <  80 THEN '08. 70-80%'
    WHEN lifecycle_pct <  90 THEN '09. 80-90%'
    ELSE                          '10. 90-100%'
  END AS lifecycle_bucket,

  COUNT(*)                                  AS nb_events,
  na.total_sold_artworks,
  ROUND(COUNT(*) / na.total_sold_artworks, 4) AS events_per_artwork

FROM lifecycle_events le
CROSS JOIN nb_artworks na
GROUP BY 1, 2, 3, na.total_sold_artworks
ORDER BY 1, 3
