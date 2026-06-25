-- BV by email 1st click campaign for the deactivated artist base.
-- Timeframe: June 2024 – February 2025 (2024-06-01 to < 2025-03-01)
-- Sales are restricted to the artist's deactivated period only (same logic as supply metrics).

WITH all_artist_plans AS (
  SELECT
    *,
    FIRST_VALUE(level)      OVER (PARTITION BY artist_id ORDER BY started_at ASC, id ASC) AS first_plan_level,
    FIRST_VALUE(started_at) OVER (PARTITION BY artist_id ORDER BY started_at ASC, id ASC) AS first_plan_started_at,
    ROW_NUMBER()            OVER (PARTITION BY artist_id ORDER BY started_at DESC, id DESC) AS rn_last
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
),

artists_before_cutoff AS (
  SELECT DISTINCT artist_id, first_plan_level, first_plan_started_at
  FROM all_artist_plans
  WHERE first_plan_started_at < '2025-03-01'
),

last_plan AS (
  SELECT artist_id, ended_at AS last_plan_ended_at
  FROM all_artist_plans
  WHERE rn_last = 1
),

ever_had_paid_sub AS (
  SELECT DISTINCT artist_id
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  WHERE level != 'selected'
),

first_paid_sub AS (
  SELECT
    artist_id,
    MIN(started_at) AS first_paid_sub_started_at
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  WHERE level != 'selected'
  GROUP BY artist_id
),

deactivated_artists AS (
  SELECT
    abc.artist_id,
    lp.last_plan_ended_at,
    fps.first_paid_sub_started_at,
    CASE
      WHEN abc.first_plan_level = 'selected' AND eps.artist_id IS NULL
        THEN 'deactivated_selected_no_migration'
      WHEN abc.first_plan_level = 'selected' AND eps.artist_id IS NOT NULL
        THEN 'deactivated_selected_migrated_churned'
      ELSE
        'deactivated_new_artist_churned'
    END AS deactivated_type
  FROM artists_before_cutoff abc
  INNER JOIN last_plan lp
    ON abc.artist_id = lp.artist_id
  LEFT JOIN ever_had_paid_sub eps
    ON abc.artist_id = eps.artist_id
  LEFT JOIN first_paid_sub fps
    ON abc.artist_id = fps.artist_id
  WHERE lp.last_plan_ended_at IS NOT NULL
    AND lp.last_plan_ended_at < CURRENT_DATE()
)

SELECT
  sa.email_1st_click_campaign_name,
  da.deactivated_type,
  COUNT(DISTINCT s.sale_id)   AS nb_sales,
  SUM(s.amount_eur_paid)      AS total_bv
FROM `singulart-data.connected_sheets.all_sales` s
INNER JOIN deactivated_artists da
  ON s.artist_id = da.artist_id
LEFT JOIN `singulart-data.connected_sheets.sales_attribution` sa
  ON sa.sale_id = s.sale_id
WHERE s.paid_at >= '2024-06-01'
  AND s.paid_at < '2025-03-01'
  AND (
    da.deactivated_type = 'deactivated_selected_no_migration'
    OR (da.deactivated_type = 'deactivated_new_artist_churned'
        AND s.paid_at >= da.last_plan_ended_at)
    OR (da.deactivated_type = 'deactivated_selected_migrated_churned'
        AND (s.paid_at < da.first_paid_sub_started_at
             OR s.paid_at >= da.last_plan_ended_at))
  )
GROUP BY 1, 2
ORDER BY total_bv DESC
