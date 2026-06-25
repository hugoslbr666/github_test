-- BV by email 1st click campaign for currently active (non-deactivated) artists.
-- Active = artists whose last plan has not ended (ended_at IS NULL or in the future).
-- Timeframe: June 2024 – February 2025 (2024-06-01 to < 2025-03-01)
-- No deactivated-period filter needed — these artists were active throughout.

WITH all_artist_plans AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY artist_id ORDER BY started_at DESC, id DESC) AS rn_last
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
),

active_artists AS (
  SELECT artist_id
  FROM all_artist_plans
  WHERE rn_last = 1
    AND (ended_at IS NULL OR ended_at >= CURRENT_DATE())
)

SELECT
  sa.email_1st_click_campaign_name,
  COUNT(DISTINCT s.sale_id)  AS nb_sales,
  SUM(s.amount_eur_paid)     AS total_bv
FROM `singulart-data.connected_sheets.all_sales` s
INNER JOIN active_artists aa
  ON s.artist_id = aa.artist_id
LEFT JOIN `singulart-data.connected_sheets.sales_attribution` sa
  ON sa.sale_id = s.sale_id
WHERE s.paid_at >= '2024-06-01'
  AND s.paid_at < '2025-03-01'
GROUP BY 1
ORDER BY total_bv DESC
