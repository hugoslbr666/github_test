-- Number of artists live in 2025 and number of selling artists in 2025
--
-- "Live in 2025"   : had an active plan at any point during calendar year 2025
--                    (plan started on or before 2025-12-31  AND  ended on or after 2025-01-01, or still active)
-- "Selling in 2025": made at least one sale (paid_at) during calendar year 2025

WITH live_in_2025 AS (
  SELECT COUNT(DISTINCT artist_id) AS nb_live_artists_2025
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  WHERE started_at <= '2025-12-31'
    AND (ended_at IS NULL OR ended_at >= '2025-01-01')
),

selling_in_2025 AS (
  SELECT COUNT(DISTINCT artist_id) AS nb_selling_artists_2025
  FROM `singulart-data.connected_sheets.all_sales`
  WHERE DATE(paid_at) BETWEEN '2025-01-01' AND '2025-12-31'
)

SELECT
  live_in_2025.nb_live_artists_2025,
  selling_in_2025.nb_selling_artists_2025
FROM live_in_2025, selling_in_2025
