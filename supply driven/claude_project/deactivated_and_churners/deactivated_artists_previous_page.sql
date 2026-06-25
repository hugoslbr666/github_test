-- Previous page before a deactivated artist page visit.
-- For each visit to a deactivated artist's page, captures the tpl and url
-- of the page visited immediately before it in the same session.
--
-- Sessions are filtered to the artist's deactivated period only:
--   selected_no_migration:       all sessions (artist was never on a paid plan)
--   new_artist_churned:          sessions AFTER last_plan_ended_at
--   selected_migrated_churned:   sessions BEFORE first paid sub started
--                                OR AFTER last paid sub ended
--
-- NOTE: uses ap.url — verify this column name exists in all_pageviews.
--       If not, prev_tpl + prev_object_id can reconstruct the page identity.
--
-- Timeframe: June 2024 – February 2025 (2024-06-01 to < 2025-03-01)

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

-- First paid (non-selected) subscription start date — used to bound the
-- "before subscription" window for selected_migrated_churned artists
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
),

-- Sessions containing a visit to a deactivated artist page,
-- filtered to the period when the artist was actually deactivated
relevant_sessions AS (
  SELECT DISTINCT ap.session_id
  FROM `singulart-data.views.all_pageviews` ap
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs
    ON stvs.id = ap.session_id
  INNER JOIN deactivated_artists da
    ON SAFE_CAST(ap.object_id AS INT64) = da.artist_id
  LEFT JOIN `singulart-data.views.bot_visitor_ids` b
    ON b.visitor_id = stvs.visitor_id
  WHERE ap.tpl = 'artist'
    AND b.visitor_id IS NULL
    AND ap.created_at >= '2024-06-01'
    AND ap.created_at < '2025-03-01'
    AND (
      -- selected_no_migration: no paid plan ever, all sessions are valid
      da.deactivated_type = 'deactivated_selected_no_migration'

      -- new_artist_churned: only sessions after the plan ended
      OR (
        da.deactivated_type = 'deactivated_new_artist_churned'
        AND ap.created_at >= da.last_plan_ended_at
      )

      -- selected_migrated_churned: sessions before the first paid sub
      -- OR after the last paid sub ended
      OR (
        da.deactivated_type = 'deactivated_selected_migrated_churned'
        AND (
          ap.created_at < da.first_paid_sub_started_at
          OR ap.created_at >= da.last_plan_ended_at
        )
      )
    )
),

-- All pageviews within those sessions, with the previous page via LAG
-- The LAG covers all page types so the previous page is always accurate
session_navigation AS (
  SELECT
    ap.session_id,
    ap.unique_pageview_id,
    ap.tpl,
    ap.object_id,
    ap.url,
    ap.created_at,
    LAG(ap.tpl)       OVER (PARTITION BY ap.session_id ORDER BY ap.created_at ASC, ap.unique_pageview_id ASC) AS prev_tpl,
    LAG(ap.url)       OVER (PARTITION BY ap.session_id ORDER BY ap.created_at ASC, ap.unique_pageview_id ASC) AS prev_url,
    LAG(ap.object_id) OVER (PARTITION BY ap.session_id ORDER BY ap.created_at ASC, ap.unique_pageview_id ASC) AS prev_object_id
  FROM `singulart-data.views.all_pageviews` ap
  INNER JOIN relevant_sessions rs
    ON ap.session_id = rs.session_id
  WHERE ap.created_at >= '2024-06-01'
    AND ap.created_at < '2025-03-01'
)

SELECT
  da.deactivated_type,
  COALESCE(sn.prev_tpl, 'direct_landing') AS prev_tpl,
  sn.prev_url,
  COUNT(*)                      AS nb_artist_page_visits,
  COUNT(DISTINCT sn.session_id) AS nb_sessions
FROM session_navigation sn
INNER JOIN deactivated_artists da
  ON SAFE_CAST(sn.object_id AS INT64) = da.artist_id
WHERE sn.tpl = 'artist'
GROUP BY 1, 2, 3
ORDER BY nb_artist_page_visits DESC
