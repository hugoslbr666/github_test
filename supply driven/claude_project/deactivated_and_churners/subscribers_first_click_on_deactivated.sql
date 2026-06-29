-- Artists who subscribed (new, non-selected) whose very first click
-- landed on a deactivated artist's page WHILE that artist was deactivated.
--
-- "While deactivated" is checked per type:
--   selected_no_migration:      click happened after their selected plan ended
--   new_artist_churned:         click happened after their last plan ended
--   selected_migrated_churned:  click happened before first paid sub
--                               OR after last paid sub ended

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

-- Deactivated artists with their period boundaries
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
),

-- Artists who ever had a selected plan (excluded from the subscriber population)
ever_selected AS (
  SELECT DISTINCT artist_id
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  WHERE level = 'selected'
)

SELECT
  aa.artist_id,
  aa.firstClickLandingTpl,
  aa.firstClicklanding_object_id,
  aa.firstClickCampaignName,
  aa.firstClickAt,
  aa.firstClickLandingPage,
  aa.firstClickReferer,
  da.deactivated_type
FROM `singulart-data.sfa_acquisition.artists_attribution` aa
INNER JOIN deactivated_artists da
  ON SAFE_CAST(aa.firstClicklanding_object_id AS INT64) = da.artist_id
-- Exclude subscribers who went through the selected path themselves
LEFT JOIN ever_selected es
  ON es.artist_id = aa.artist_id
WHERE aa.firstClickLandingTpl = 'artist'
  AND aa.new_artist = 1
  AND es.artist_id IS NULL
  -- The click happened while the landed-on artist was actually deactivated
  AND (
    (
      da.deactivated_type = 'deactivated_selected_no_migration'
      AND aa.firstClickAt >= da.last_plan_ended_at
    )
    OR (
      da.deactivated_type = 'deactivated_new_artist_churned'
      AND aa.firstClickAt >= da.last_plan_ended_at
    )
    OR (
      da.deactivated_type = 'deactivated_selected_migrated_churned'
      AND (
        aa.firstClickAt < da.first_paid_sub_started_at
        OR aa.firstClickAt >= da.last_plan_ended_at
      )
    )
  )
ORDER BY aa.firstClickAt DESC
