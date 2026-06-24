WITH
buyers_list AS (
  SELECT visitor_id
  FROM `singulart-data.views.visitor_attribution`
  WHERE first_order_at IS NOT NULL
),

-- For sold artworks, only count impressions that happened before the sale
sold_artwork_dates AS (
  SELECT
    artwork_id,
    MIN(paid_at) AS paid_at
  FROM `singulart-data.connected_sheets.all_sales`
  WHERE paid_at >= DATE_SUB(CURRENT_DATE, INTERVAL 6 MONTH)
  GROUP BY artwork_id
),

artworks_scope AS (
  SELECT
    aa.artwork_id,
    CASE WHEN sad.paid_at IS NOT NULL THEN 'sold' ELSE 'available' END AS status
  FROM `singulart-data.connected_sheets.all_artworks` aa
  LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = aa.artwork_id
  WHERE aa.is_hiearchically_online = 1
     OR sad.paid_at IS NOT NULL
),

impressions_buyers AS (
  SELECT
    SAFE_CAST(i.item_id AS INT64) AS artwork_id,
    COUNT(DISTINCT ge.new_eventId) AS nb_impressions_buyers
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN buyers_list bl ON bl.visitor_id = ge.visitor_id
  LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = SAFE_CAST(i.item_id AS INT64)
  WHERE ge.event_name = 'view_item_list'
    AND ge.event_date >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
    AND (sad.paid_at IS NULL OR ge.event_date < sad.paid_at)
  GROUP BY 1
),

impressions_all AS (
  SELECT
    SAFE_CAST(i.item_id AS INT64) AS artwork_id,
    COUNT(DISTINCT ge.new_eventId) AS nb_impressions_all
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  LEFT JOIN sold_artwork_dates sad ON sad.artwork_id = SAFE_CAST(i.item_id AS INT64)
  WHERE ge.event_name = 'view_item_list'
    AND ge.event_date >= DATE_SUB(CURRENT_DATE, INTERVAL 24 MONTH)
    AND (sad.paid_at IS NULL OR ge.event_date < sad.paid_at)
  GROUP BY 1
),

artwork_metrics AS (
  SELECT
    a.artwork_id,
    a.status,
    COALESCE(ib.nb_impressions_buyers, 0) AS nb_impressions_buyers,
    COALESCE(ia.nb_impressions_all, 0)    AS nb_impressions_all
  FROM artworks_scope a
  LEFT JOIN impressions_buyers ib ON ib.artwork_id = a.artwork_id
  LEFT JOIN impressions_all    ia ON ia.artwork_id = a.artwork_id
  WHERE COALESCE(ib.nb_impressions_buyers, 0) > 0
     OR COALESCE(ia.nb_impressions_all, 0) > 0
)

SELECT
  status,
  COUNT(*)                                                                   AS nb_artworks,
  -- Buyer impressions
  ROUND(AVG(nb_impressions_buyers), 1)                                       AS avg_impressions_buyers,
  ROUND(APPROX_QUANTILES(nb_impressions_buyers, 2)[OFFSET(1)], 1)           AS median_impressions_buyers,
  SUM(nb_impressions_buyers)                                                 AS total_impressions_buyers,
  -- All-user impressions
  ROUND(AVG(nb_impressions_all), 1)                                          AS avg_impressions_all,
  ROUND(APPROX_QUANTILES(nb_impressions_all, 2)[OFFSET(1)], 1)              AS median_impressions_all,
  SUM(nb_impressions_all)                                                    AS total_impressions_all,
  -- Buyer share
  ROUND(SAFE_DIVIDE(SUM(nb_impressions_buyers), SUM(nb_impressions_all)), 4) AS buyer_impression_share
FROM artwork_metrics
GROUP BY 1
ORDER BY 1
