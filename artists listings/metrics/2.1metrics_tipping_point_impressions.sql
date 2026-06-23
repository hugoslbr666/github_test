WITH
buyers_list AS (
  SELECT visitor_id
  FROM `singulart-data.views.visitor_attribution`
  WHERE first_order_at IS NOT NULL
),

sold_artwork_dates AS (
  SELECT artwork_id, MIN(paid_at) AS paid_at
  FROM `singulart-data.connected_sheets.all_sales`
  WHERE paid_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)
  GROUP BY artwork_id
),

artworks_base AS (
  SELECT
    aa.artwork_id,
    aa.artist_id,
    aa.is_hiearchically_online,
    a_s.paid_at
  FROM `singulart-data.connected_sheets.all_artworks` aa
  LEFT JOIN `singulart-data.connected_sheets.all_sales` a_s
    ON a_s.artwork_id = aa.artwork_id
    AND a_s.paid_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH)
  WHERE (aa.is_hiearchically_online = 1 OR a_s.paid_at >= DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH))
),

-- Buyer impressions per artwork from artwork listing pages only (pre-sale)
impressions AS (
  SELECT
    SAFE_CAST(i.item_id AS INT64) AS artwork_id,
    COUNT(DISTINCT ge.new_eventId)  AS nb_impressions
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN buyers_list bl ON bl.visitor_id = ge.visitor_id
  LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = SAFE_CAST(i.item_id AS INT64)
  WHERE ge.event_name = 'view_item_list'
    --AND i.item_list_name IN ('ap', 'ap-l')
    AND ge.event_date >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
    AND (sad.paid_at IS NULL OR ge.event_date < sad.paid_at)
  GROUP BY 1
),

-- Buyer clicks per artwork (pre-sale)
clicks AS (
  SELECT
    SAFE_CAST(pv.object_id AS INT64) AS artwork_id,
    COUNT(*) AS nb_clicks
  FROM `singulart-data.views.all_pageviews` pv
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = pv.session_id
  INNER JOIN buyers_list bl ON bl.visitor_id = s.visitor_id
  LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = SAFE_CAST(pv.object_id AS INT64)
  WHERE pv.tpl = 'artwork'
    AND pv.created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
    AND (sad.paid_at IS NULL OR pv.created_at < sad.paid_at)
  GROUP BY 1
),

-- Buyer wishlists per artwork (pre-sale)
wishlists AS (
  SELECT
    wishlist.artwork_id,
    COUNT(DISTINCT wishlist_id) AS nb_wishlists
  FROM `singulart-data.connected_sheets.all_wishlists` wishlist
  INNER JOIN buyers_list bl ON bl.visitor_id = wishlist.visitor_id
  LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = wishlist.artwork_id
  WHERE wishlist.wishlist_created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 24  MONTH)
    AND (sad.paid_at IS NULL OR wishlist.wishlist_created_at < sad.paid_at)
  GROUP BY 1
),

-- Buyer add-to-carts per artwork (pre-sale)
add_to_cart AS (
  SELECT
    scl.artwork_id,
    COUNT(DISTINCT scl.cart_id) AS nb_add_to_cart
  FROM `singulart-db-to-bigquery.singulartdb.sgt_carts_lines` scl
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_carts` sc ON sc.id = scl.cart_id
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = sc.browsing_session_id
  INNER JOIN buyers_list bl ON bl.visitor_id = s.visitor_id
  LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = scl.artwork_id
  WHERE sc.created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
    AND (sad.paid_at IS NULL OR sc.created_at < sad.paid_at)
  GROUP BY 1
),

artwork_metrics AS (
  SELECT
    ab.artwork_id,
    CASE WHEN ab.paid_at IS NOT NULL THEN 'sold' ELSE 'available' END AS status,
    imp.nb_impressions,
    COALESCE(c.nb_clicks, 0)        AS nb_clicks,
    COALESCE(w.nb_wishlists, 0)     AS nb_wishlists,
    COALESCE(atc.nb_add_to_cart, 0) AS nb_add_to_cart
  FROM artworks_base ab
  INNER JOIN impressions imp ON imp.artwork_id = ab.artwork_id  -- must have at least 1 buyer impression
  LEFT JOIN clicks      c   ON c.artwork_id   = ab.artwork_id
  LEFT JOIN wishlists   w   ON w.artwork_id   = ab.artwork_id
  LEFT JOIN add_to_cart atc ON atc.artwork_id = ab.artwork_id
)

SELECT
  status,
  CASE
    WHEN nb_impressions > 500 THEN '11. 501+ impressions'
    ELSE CONCAT(
      LPAD(CAST(CAST(FLOOR((nb_impressions - 1) / 50) AS INT64) + 1 AS STRING), 2, '0'),
      '. ',
      CAST(CAST(FLOOR((nb_impressions - 1) / 50) AS INT64) * 50 + 1  AS STRING),
      '-',
      CAST(CAST(FLOOR((nb_impressions - 1) / 50) AS INT64) * 50 + 50 AS STRING),
      ' impressions'
    )
  END                                                                AS impression_bucket,
  COUNT(*)                                                           AS nb_artworks,

  -- % of artworks in this bucket that had at least 1 engagement event
  -- (analogous to pct_with_any_event in the tipping point day-based analysis)
  ROUND(COUNTIF(nb_clicks > 0)       / COUNT(*), 4)                 AS pct_with_click,
  ROUND(COUNTIF(nb_wishlists > 0)    / COUNT(*), 4)                 AS pct_with_wishlist,
  ROUND(COUNTIF(nb_add_to_cart > 0)  / COUNT(*), 4)                 AS pct_with_add_to_cart,

  -- Conversion rate per impression (avg across artworks in the bucket)
  ROUND(AVG(SAFE_DIVIDE(nb_clicks,       nb_impressions)), 4)       AS avg_click_rate,
  ROUND(AVG(SAFE_DIVIDE(nb_wishlists,    nb_impressions)), 4)       AS avg_wishlist_rate,
  ROUND(AVG(SAFE_DIVIDE(nb_add_to_cart,  nb_impressions)), 4)       AS avg_add_to_cart_rate

FROM artwork_metrics
GROUP BY 1, 2
ORDER BY 1, 2
