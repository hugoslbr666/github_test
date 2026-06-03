WITH
buyers_list AS (
  SELECT
    visitor_id
  FROM `singulart-data.views.visitor_attribution`
  WHERE first_order_at IS NOT NULL
),

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
    CASE
      WHEN cumulative_pct <= 25 THEN '1. Top 25%'
      WHEN cumulative_pct <= 50 THEN '2. Top 25-50%'
      WHEN cumulative_pct <= 75 THEN '3. Top 50-75%'
      ELSE '4. Bottom 25%'
    END AS segment
  FROM with_cumulative
),

artworks_and_sales_L6_months AS (
  SELECT
    aa.artwork_id,
    aa.artist_id,
    a_a.artist_name,
    aa.artwork_online_at,
    aa.price_eur,
    is_hiearchically_online,
    a_s.paid_at
  FROM `singulart-data.connected_sheets.all_artworks` aa
  INNER JOIN `singulart-data.connected_sheets.all_artists` a_a ON a_a.artist_id = aa.artist_id
  LEFT JOIN `singulart-data.connected_sheets.all_sales` a_s ON a_s.artwork_id = aa.artwork_id AND paid_at >= DATE_SUB(CURRENT_DATE, INTERVAL 6 MONTH)
  WHERE (is_hiearchically_online = 1 OR paid_at >= DATE_SUB(CURRENT_DATE, INTERVAL 6 MONTH))
),

views AS (
  SELECT
    aa.artwork_id,
    COUNT(DISTINCT ge.new_eventId) AS nb_views_total
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN `singulart-data.connected_sheets.all_artworks` aa  ON aa.artwork_id = SAFE_CAST(i.item_id AS INT64)
  INNER JOIN `singulart-data.connected_sheets.all_artists` a_a  ON a_a.artist_id = aa.artist_id
  INNER JOIN buyers_list bl ON bl.visitor_id = ge.visitor_id
  WHERE event_date >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)
    AND ge.event_name = 'view_item_list'
  GROUP BY 1
),

clicks AS (
  SELECT
    SAFE_CAST(pv.object_id AS INT64) AS artwork_id,
    COUNT(*) AS nb_clicks
  FROM `singulart-data.views.all_pageviews` pv
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = pv.session_id
  INNER JOIN buyers_list bl ON bl.visitor_id = s.visitor_id
  WHERE pv.tpl = 'artwork'
    AND pv.created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)
  GROUP BY 1
),

wishlists AS (
  SELECT
    artwork_id,
    COUNT(DISTINCT wishlist_id) AS nb_wishlist_events
  FROM `singulart-data.connected_sheets.all_wishlists` wishlist
  INNER JOIN buyers_list bl ON bl.visitor_id = wishlist.visitor_id
  WHERE wishlist_created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)
  GROUP BY 1
),

add_to_cart AS (
  SELECT
    artwork_id,
    COUNT(DISTINCT cart_id) AS nb_add_to_cart_events
  FROM `singulart-db-to-bigquery.singulartdb.sgt_carts_lines` scl
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_carts` sc ON sc.id = scl.cart_id
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = sc.browsing_session_id
  INNER JOIN buyers_list bl ON bl.visitor_id = s.visitor_id
  WHERE sc.created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)
  GROUP BY 1
),

artwork_metrics AS (
  SELECT
    asl.artwork_id,
    asl.artist_id,
    asl.artist_name,
    CASE WHEN asl.paid_at IS NOT NULL THEN 'sold' ELSE 'available' END AS status,
    COALESCE(qs.segment, '4. Bottom 25%') AS segment,
    qs.total_bv,
    v.nb_views_total,
    COALESCE(w.nb_wishlist_events, 0)      AS nb_wishlist_events,
    COALESCE(c.nb_clicks, 0)               AS nb_clicks,
    COALESCE(atc.nb_add_to_cart_events, 0) AS nb_add_to_cart_events,
    SAFE_DIVIDE(COALESCE(w.nb_wishlist_events, 0),      v.nb_views_total) AS wishlist_per_view,
    SAFE_DIVIDE(COALESCE(c.nb_clicks, 0),               v.nb_views_total) AS clicks_per_view,
    SAFE_DIVIDE(COALESCE(atc.nb_add_to_cart_events, 0), v.nb_views_total) AS add_to_cart_per_view
  FROM artworks_and_sales_L6_months asl
  INNER JOIN views v     ON v.artwork_id   = asl.artwork_id
  LEFT JOIN  clicks c    ON c.artwork_id   = asl.artwork_id
  LEFT JOIN  wishlists w ON w.artwork_id   = asl.artwork_id
  LEFT JOIN  add_to_cart atc ON atc.artwork_id = asl.artwork_id
  LEFT JOIN  quartile_split qs ON qs.artist_id = asl.artist_id
)

SELECT
  segment,
  artist_name,
  MAX(total_bv)                                                                              AS total_bv,
  -- Wishlist / Views
  ROUND(AVG(IF(status = 'sold',      wishlist_per_view, NULL)), 4)                          AS avg_wishlist_per_view_sold,
  ROUND(AVG(IF(status = 'available', wishlist_per_view, NULL)), 4)                          AS avg_wishlist_per_view_available,
  ROUND(APPROX_QUANTILES(IF(status = 'sold',      wishlist_per_view, NULL), 2)[OFFSET(1)], 4) AS median_wishlist_per_view_sold,
  ROUND(APPROX_QUANTILES(IF(status = 'available', wishlist_per_view, NULL), 2)[OFFSET(1)], 4) AS median_wishlist_per_view_available,
  -- Clicks / Views
  ROUND(AVG(IF(status = 'sold',      clicks_per_view, NULL)), 4)                            AS avg_clicks_per_view_sold,
  ROUND(AVG(IF(status = 'available', clicks_per_view, NULL)), 4)                            AS avg_clicks_per_view_available,
  ROUND(APPROX_QUANTILES(IF(status = 'sold',      clicks_per_view, NULL), 2)[OFFSET(1)], 4) AS median_clicks_per_view_sold,
  ROUND(APPROX_QUANTILES(IF(status = 'available', clicks_per_view, NULL), 2)[OFFSET(1)], 4) AS median_clicks_per_view_available,
  -- Add to Cart / Views
  ROUND(AVG(IF(status = 'sold',      add_to_cart_per_view, NULL)), 4)                       AS avg_add_to_cart_per_view_sold,
  ROUND(AVG(IF(status = 'available', add_to_cart_per_view, NULL)), 4)                       AS avg_add_to_cart_per_view_available,
  ROUND(APPROX_QUANTILES(IF(status = 'sold',      add_to_cart_per_view, NULL), 2)[OFFSET(1)], 4) AS median_add_to_cart_per_view_sold,
  ROUND(APPROX_QUANTILES(IF(status = 'available', add_to_cart_per_view, NULL), 2)[OFFSET(1)], 4) AS median_add_to_cart_per_view_available
FROM artwork_metrics
GROUP BY 1, 2
ORDER BY total_bv DESC
