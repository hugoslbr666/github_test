-- Reconstructed "deactivated" artist base.
--
-- Covers all artists who were on Singulart BEFORE 2025-03-01 and are no longer active:
--   deactivated_type 1 — selected_no_migration:      first plan was 'selected', ended, never got a paid sub
--   deactivated_type 2 — selected_migrated_churned:  first plan was 'selected', got a paid sub, last paid sub ended
--   deactivated_type 3 — new_artist_churned:         first plan was a paid plan (not 'selected'), last paid sub ended

WITH all_artist_plans AS (
  SELECT
    *,
    -- First plan info per artist
    FIRST_VALUE(level)      OVER (PARTITION BY artist_id ORDER BY started_at ASC, id ASC) AS first_plan_level,
    FIRST_VALUE(started_at) OVER (PARTITION BY artist_id ORDER BY started_at ASC, id ASC) AS first_plan_started_at,
    -- Rank plans most-recent-first to identify the last active plan
    ROW_NUMBER()            OVER (PARTITION BY artist_id ORDER BY started_at DESC, id DESC) AS rn_last
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
),

-- Artists whose first plan started before the cutoff
artists_before_cutoff AS (
  SELECT DISTINCT
    artist_id,
    first_plan_level,
    first_plan_started_at
  FROM all_artist_plans
  WHERE first_plan_started_at < '2025-03-01'
),

-- Most recent plan per artist (used to test whether they are still active)
last_plan AS (
  SELECT
    artist_id,
    level         AS last_plan_level,
    ended_at      AS last_plan_ended_at,
    started_at    AS last_plan_started_at
  FROM all_artist_plans
  WHERE rn_last = 1
),

-- Artists who had at least one paid (non-selected) subscription
ever_had_paid_sub AS (
  SELECT DISTINCT artist_id
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  WHERE level != 'selected'
)

SELECT
  abc.artist_id,
  art.artist_name,
  art.status AS current_status,
  abc.first_plan_level,
  abc.first_plan_started_at,
  lp.last_plan_level,
  lp.last_plan_ended_at,
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
LEFT JOIN `singulart-data.connected_sheets.all_artists` art
  ON art.artist_id = abc.artist_id
WHERE
  -- Currently inactive: last plan has ended before today
  lp.last_plan_ended_at IS NOT NULL
  AND lp.last_plan_ended_at < CURRENT_DATE()
ORDER BY abc.artist_id
