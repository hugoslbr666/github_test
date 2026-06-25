-- Artists whose first plan was 'selected', with their current subscription status.
--
-- Status 1: selected plan is ongoing (ended_at IS NULL)
-- Status 2: selected plan ended, no other subscriptions
-- Status 3: selected plan ended, has other subscriptions, last one is still active (ended_at IS NULL or > now)
-- Status 4: selected plan ended, has other subscriptions, last one also ended before now (churned)

WITH artists_first_selected AS (
  -- Keep only artists whose very first plan (by started_at) was 'selected'
  SELECT artist_id
  FROM (
    SELECT
      artist_id,
      level,
      ROW_NUMBER() OVER (PARTITION BY artist_id ORDER BY started_at ASC, id ASC) AS rn
    FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  )
  WHERE rn = 1
    AND level = 'selected'
),

artist_plans AS (
  SELECT sap.*
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans` sap
  INNER JOIN artists_first_selected afs ON sap.artist_id = afs.artist_id
),

selected_plan AS (
  SELECT
    artist_id,
    MAX(ended_at) AS selected_ended_at
  FROM artist_plans
  WHERE level = 'selected'
  GROUP BY artist_id
),

last_other_sub AS (
  -- Most recent non-selected subscription per artist
  SELECT
    artist_id,
    ended_at AS last_sub_ended_at
  FROM (
    SELECT
      artist_id,
      ended_at,
      ROW_NUMBER() OVER (PARTITION BY artist_id ORDER BY started_at DESC, id DESC) AS rn
    FROM artist_plans
    WHERE level != 'selected'
  )
  WHERE rn = 1
)

SELECT
  sp.artist_id,
  artists.artist_name,
  status,
  CASE
    WHEN sp.selected_ended_at IS NULL
      THEN 'status_1_selected_ongoing'
    WHEN sp.selected_ended_at IS NOT NULL
      AND los.artist_id IS NULL
      THEN 'status_2_selected_ended_no_resub'
    WHEN sp.selected_ended_at IS NOT NULL
      AND los.artist_id IS NOT NULL
      AND (los.last_sub_ended_at IS NULL OR los.last_sub_ended_at > current_date())
      THEN 'status_3_currently_subscribed'
    WHEN sp.selected_ended_at IS NOT NULL
      AND los.artist_id IS NOT NULL
      AND los.last_sub_ended_at IS NOT NULL
      AND los.last_sub_ended_at < current_date()
      THEN 'status_4_churned'
  END AS status
FROM selected_plan sp
LEFT JOIN last_other_sub los ON sp.artist_id = los.artist_id
LEFT JOIN `singulart-data.connected_sheets.all_artists` artists on artists.artist_id = sp.artist_id
ORDER BY sp.artist_id
