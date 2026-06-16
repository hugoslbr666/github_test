WITH plans AS (
  SELECT
    artist_id,
    DATE(MIN(started_at)) AS min_start_date,
    DATE(MAX(ended_at))   AS max_end_date
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  GROUP BY 1
)

SELECT
  DATE(DATE_TRUNC(sa.paid_at, MONTH)) AS year_month,
  aa.artist_id,
  CASE
    WHEN is_deactivated = 1 AND aa.updated_at <  sa.paid_at THEN 'deactivated'
    WHEN is_deactivated = 1 AND aa.updated_at >= sa.paid_at THEN 'before_deactivated'
    WHEN is_deactivated = 0 AND min_start_date IS NULL AND max_end_date IS NULL THEN 'no_migration'
    WHEN is_deactivated = 0 AND max_end_date <  sa.paid_at                      THEN 'churned'
    WHEN is_deactivated = 0 AND max_end_date >= sa.paid_at                      THEN 'live'
    WHEN is_deactivated = 0 AND min_start_date IS NOT NULL                      THEN 'live'
    ELSE 'unknown'
  END AS artist_status,
  is_deactivated,
  min_start_date,
  max_end_date,
  aa.updated_at,
  sale_id,
  any_value(sa.purchaseEurAmountWithShipping) AS BV_first_click
FROM `singulart-data.connected_sheets.sales_attribution` sa
INNER JOIN `singulart-data.connected_sheets.all_artists` aa
  ON SAFE_CAST(aa.artist_id AS STRING) = sa.email_1st_click_landing_object_id
LEFT JOIN plans
  ON plans.artist_id = aa.artist_id
WHERE sa.email_1st_click_campaign_name = "TEMPLATE ARTIST"
  AND sa.email_1st_click_landing_tpl = "artist"
  AND sa.paid_at >= "2023-09-01"
GROUP BY ALL
ORDER BY BV_first_click DESC
