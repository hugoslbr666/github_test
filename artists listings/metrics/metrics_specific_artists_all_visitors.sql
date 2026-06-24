--all_visitors

WITH
target_artists AS (
  SELECT artist_id
  FROM UNNEST([259, 2493, 4545, 11651, 2099, 7037, 14061, 63, 4475, 1973]) AS artist_id
),

sold_artwork_dates AS (
  SELECT
    artwork_id,
    MIN(paid_at) AS paid_at
  FROM `singulart-data.connected_sheets.all_sales`
  WHERE paid_at >= DATE_SUB(CURRENT_DATE, INTERVAL 6 MONTH)
  GROUP BY artwork_id
),

ever_sold_artworks AS (
  SELECT
    artwork_id,
    MIN(paid_at) AS first_sold_at
  FROM `singulart-data.connected_sheets.all_sales`
  GROUP BY artwork_id
),

target_artworks AS (
  SELECT DISTINCT
    artwork_id,
    artist_id,
    title,
    price_eur
  FROM `singulart-data.connected_sheets.all_artworks`
  WHERE artist_id IN (SELECT artist_id FROM target_artists)
    AND (
      artwork_id IN (SELECT artwork_id FROM ever_sold_artworks)
      OR (is_hiearchically_online = 1 AND available_for_purchase = 1)
    )
),

impressions AS (
  SELECT
    aa.artwork_id,
    COUNT(DISTINCT ge.new_eventId) AS nb_impressions
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN target_artworks aa ON aa.artwork_id = SAFE_CAST(i.item_id AS INT64)
  LEFT JOIN ever_sold_artworks esa ON esa.artwork_id = aa.artwork_id
  WHERE ge.event_name = 'view_item_list'
    AND (esa.first_sold_at IS NULL OR ge.event_date < esa.first_sold_at)
  GROUP BY 1
),

add_to_cart AS (
  SELECT
    scl.artwork_id,
    COUNT(DISTINCT scl.cart_id) AS nb_add_to_cart
  FROM `singulart-db-to-bigquery.singulartdb.sgt_carts_lines` scl
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_carts` sc ON sc.id = scl.cart_id
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = sc.browsing_session_id
  INNER JOIN target_artworks aa ON aa.artwork_id = scl.artwork_id
  LEFT JOIN ever_sold_artworks esa ON esa.artwork_id = scl.artwork_id
  WHERE (esa.first_sold_at IS NULL OR sc.created_at < esa.first_sold_at)
  GROUP BY 1
),

wishlists AS (
  SELECT
    w.artwork_id,
    COUNT(DISTINCT w.wishlist_id) AS nb_wishlist
  FROM `singulart-data.connected_sheets.all_wishlists` w
  INNER JOIN target_artworks aa ON aa.artwork_id = w.artwork_id
  LEFT JOIN ever_sold_artworks esa ON esa.artwork_id = w.artwork_id
  WHERE (esa.first_sold_at IS NULL OR w.wishlist_created_at < esa.first_sold_at)
  GROUP BY 1
),

clicks AS (
  SELECT
    SAFE_CAST(pv.object_id AS INT64) AS artwork_id,
    COUNT(*) AS nb_clicks
  FROM `singulart-data.views.all_pageviews` pv
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = pv.session_id
  INNER JOIN target_artworks aa ON aa.artwork_id = SAFE_CAST(pv.object_id AS INT64)
  LEFT JOIN ever_sold_artworks esa ON esa.artwork_id = SAFE_CAST(pv.object_id AS INT64)
  WHERE pv.tpl = 'artwork'
    AND (esa.first_sold_at IS NULL OR pv.created_at < esa.first_sold_at)
  GROUP BY 1
)

SELECT
  a_a.artist_id,
  a_a.artist_name,
  aa.artwork_id,
  aa.title,
  CASE
    WHEN sad.paid_at IS NOT NULL THEN 'sold_l6m'
    WHEN esa.artwork_id IS NOT NULL THEN 'sold_old'
    ELSE 'available'
  END AS status,
  price_eur,
  i.nb_impressions,
  COALESCE(atc.nb_add_to_cart, 0)                                             AS nb_add_to_cart,
  COALESCE(wl.nb_wishlist, 0)                                                 AS nb_wishlist,
  COALESCE(c.nb_clicks, 0)                                                    AS nb_clicks,
  ROUND(SAFE_DIVIDE(COALESCE(atc.nb_add_to_cart, 0), i.nb_impressions), 4)   AS add_to_cart_per_impression,
  ROUND(SAFE_DIVIDE(COALESCE(wl.nb_wishlist, 0),     i.nb_impressions), 4)   AS wishlist_per_impression,
  ROUND(SAFE_DIVIDE(COALESCE(c.nb_clicks, 0),        i.nb_impressions), 4)   AS click_per_impression
FROM target_artworks aa
INNER JOIN `singulart-data.connected_sheets.all_artists` a_a ON a_a.artist_id = aa.artist_id
INNER JOIN impressions i      ON i.artwork_id  = aa.artwork_id
LEFT JOIN  add_to_cart atc    ON atc.artwork_id = aa.artwork_id
LEFT JOIN  wishlists wl       ON wl.artwork_id  = aa.artwork_id
LEFT JOIN  clicks c           ON c.artwork_id   = aa.artwork_id
LEFT JOIN  sold_artwork_dates sad ON sad.artwork_id  = aa.artwork_id
LEFT JOIN  ever_sold_artworks esa ON esa.artwork_id  = aa.artwork_id
ORDER BY a_a.artist_id, aa.artwork_id
