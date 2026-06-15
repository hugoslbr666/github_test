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
    CASE WHEN sad.paid_at IS NOT NULL THEN 'sold' ELSE 'available' END AS status
  FROM `singulart-data.connected_sheets.all_artworks` aa
  LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = aa.artwork_id
  WHERE (aa.is_hiearchically_online = 1 OR sad.paid_at IS NOT NULL)
    AND aa.artwork_online_at IS NOT NULL
    AND DATE(aa.artwork_online_at) >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
),

-- Last signal date per artwork: latest of last click, last wishlist, last add-to-cart (pre-sale only)
last_signal AS (
  SELECT artwork_id, MAX(signal_date) AS last_signal_date
  FROM (
    SELECT
      SAFE_CAST(pv.object_id AS INT64) AS artwork_id,
      DATE(pv.created_at)              AS signal_date
    FROM `singulart-data.views.all_pageviews` pv
    INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s ON s.id = pv.session_id
    INNER JOIN buyers_list bl ON bl.visitor_id = s.visitor_id
    LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = SAFE_CAST(pv.object_id AS INT64)
    WHERE pv.tpl = 'artwork'
      AND pv.created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
      AND (sad.paid_at IS NULL OR pv.created_at < sad.paid_at)

    UNION ALL

    SELECT
      wishlist.artwork_id,
      DATE(wishlist.wishlist_created_at)
    FROM `singulart-data.connected_sheets.all_wishlists` wishlist
    INNER JOIN buyers_list bl ON bl.visitor_id = wishlist.visitor_id
    LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = wishlist.artwork_id
    WHERE wishlist.wishlist_created_at >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
      AND (sad.paid_at IS NULL OR wishlist.wishlist_created_at < sad.paid_at)

  )
  GROUP BY artwork_id
),

-- Buyer impressions received AFTER the last signal (pre-sale only)
impressions_after_signal AS (
  SELECT
    SAFE_CAST(i.item_id AS INT64) AS artwork_id,
    COUNT(DISTINCT ge.new_eventId)  AS nb_impressions_after_signal
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN buyers_list bl ON bl.visitor_id = ge.visitor_id
  INNER JOIN last_signal ls ON ls.artwork_id = SAFE_CAST(i.item_id AS INT64)
  LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = SAFE_CAST(i.item_id AS INT64)
  WHERE ge.event_name = 'view_item_list'
    AND ge.event_date > ls.last_signal_date            -- strictly after the last signal
    AND ge.event_date >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
    AND (sad.paid_at IS NULL OR ge.event_date < sad.paid_at)
  GROUP BY 1
)

SELECT
  ab.status,
  CASE
    WHEN COALESCE(ias.nb_impressions_after_signal, 0) = 0   THEN '01. 0 impressions'
    WHEN ias.nb_impressions_after_signal <=  50              THEN '02. 1-50 impressions'
    WHEN ias.nb_impressions_after_signal <= 100              THEN '03. 51-100 impressions'
    WHEN ias.nb_impressions_after_signal <= 200              THEN '04. 101-200 impressions'
    WHEN ias.nb_impressions_after_signal <= 300              THEN '05. 201-300 impressions'
    WHEN ias.nb_impressions_after_signal <= 500              THEN '06. 301-500 impressions'
    WHEN ias.nb_impressions_after_signal <= 1000             THEN '07. 501-1000 impressions'
    ELSE                                                          '08. 1000+ impressions'
  END                                                       AS impressions_after_last_signal,
  COUNT(*)                                                  AS nb_artworks,
  ROUND(COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY ab.status), 4) AS pct_of_status,
  ROUND(SUM(COUNT(*)) OVER (
    PARTITION BY ab.status
    ORDER BY MIN(COALESCE(ias.nb_impressions_after_signal, 0))
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) / SUM(COUNT(*)) OVER (PARTITION BY ab.status), 4)      AS cumulative_pct

FROM artworks_base ab
INNER JOIN last_signal ls ON ls.artwork_id = ab.artwork_id  -- only artworks that had at least 1 signal
LEFT JOIN impressions_after_signal ias ON ias.artwork_id = ab.artwork_id
GROUP BY 1, 2
ORDER BY 1, 2
