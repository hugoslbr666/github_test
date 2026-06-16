-- Sales volume and conversion rate (sales / impressions) per medium × price bracket
-- Price bracket is based on the artwork's listed price_eur.
-- Impressions = view_item_list events from GA (all placements).

WITH views AS (
  SELECT
    SAFE_CAST(i.item_id AS INT64)   AS artwork_id,
    COUNT(DISTINCT ge.new_eventId)  AS view_count
  FROM `singulart-data.ga_events.ga_events` ge,
  UNNEST(ge.items) AS i
  WHERE ge.event_name = 'view_item_list'
    AND i.item_id IS NOT NULL
  GROUP BY i.item_id
),

sales AS (
  SELECT
    artwork_id,
    COUNT(*) AS sale_count
  FROM `singulart-data.connected_sheets.all_sales`
  GROUP BY artwork_id
)

SELECT
  a.medium,
  CASE
    WHEN a.price_eur <   500 THEN '1. 0 – 500 €'
    WHEN a.price_eur <  1500 THEN '2. 500 – 1 500 €'
    WHEN a.price_eur <  5000 THEN '3. 1 500 – 5 000 €'
    WHEN a.price_eur < 10000 THEN '4. 5 000 – 10 000 €'
    ELSE                          '5. 10 000 €+'
  END                                                    AS price_bracket,
  SUM(COALESCE(s.sale_count, 0))                         AS total_sales,
  SUM(COALESCE(v.view_count, 0))                         AS total_impressions,
  ROUND(
    SAFE_DIVIDE(
      SUM(COALESCE(s.sale_count, 0)),
      SUM(COALESCE(v.view_count, 0))
    ) * 100, 4
  )                                                      AS conversion_rate_pct
FROM `singulart-data.connected_sheets.all_artworks` a
LEFT JOIN views  v USING (artwork_id)
LEFT JOIN sales  s USING (artwork_id)
WHERE a.medium    IS NOT NULL
  AND a.price_eur IS NOT NULL
GROUP BY a.medium, price_bracket
ORDER BY a.medium, price_bracket
