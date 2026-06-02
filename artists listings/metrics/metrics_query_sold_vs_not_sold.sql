WITH
buyers_list AS (
  SELECT
    visitor_id
  FROM `singulart-data.views.visitor_attribution`
  WHERE first_order_at IS NOT NULL
),

artworks_and_sales_L6_months AS (
  SELECT
    aa.artwork_id,
    aa.artwork_online_at,
    aa.price_eur,
    is_hiearchically_online,
    a_s.paid_at
  FROM `singulart-data.connected_sheets.all_artworks` aa
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
    CASE WHEN asl.paid_at IS NOT NULL THEN 'sold' ELSE 'available' END AS status,
    v.nb_views_total,
    COALESCE(w.nb_wishlist_events, 0)     AS nb_wishlist_events,
    COALESCE(c.nb_clicks, 0)              AS nb_clicks,
    COALESCE(atc.nb_add_to_cart_events, 0) AS nb_add_to_cart_events,
    SAFE_DIVIDE(COALESCE(w.nb_wishlist_events, 0),      v.nb_views_total) AS wishlist_per_view,
    SAFE_DIVIDE(COALESCE(c.nb_clicks, 0),               v.nb_views_total) AS clicks_per_view,
    SAFE_DIVIDE(COALESCE(atc.nb_add_to_cart_events, 0), v.nb_views_total) AS add_to_cart_per_view
  FROM artworks_and_sales_L6_months asl
  INNER JOIN views v ON v.artwork_id = asl.artwork_id  -- only artworks with at least 1 buyer view
  LEFT JOIN  clicks  c   ON c.artwork_id   = asl.artwork_id
  LEFT JOIN  wishlists w ON w.artwork_id   = asl.artwork_id
  LEFT JOIN  add_to_cart atc ON atc.artwork_id = asl.artwork_id
)

SELECT
  status,
  COUNT(*)                                                           AS nb_artworks,
  -- Wishlist / Views
  ROUND(AVG(wishlist_per_view), 4)                                   AS avg_wishlist_per_view,
  ROUND(APPROX_QUANTILES(wishlist_per_view, 2)[OFFSET(1)], 4)       AS median_wishlist_per_view,
  -- Clicks / Views
  ROUND(AVG(clicks_per_view), 4)                                     AS avg_clicks_per_view,
  ROUND(APPROX_QUANTILES(clicks_per_view, 2)[OFFSET(1)], 4)         AS median_clicks_per_view,
  -- Add to Cart / Views
  ROUND(AVG(add_to_cart_per_view), 4)                                AS avg_add_to_cart_per_view,
  ROUND(APPROX_QUANTILES(add_to_cart_per_view, 2)[OFFSET(1)], 4)    AS median_add_to_cart_per_view
FROM artwork_metrics
GROUP BY 1
ORDER BY 1