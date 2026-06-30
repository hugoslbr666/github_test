WITH age_levels AS (
  SELECT age_n FROM UNNEST(GENERATE_ARRAY(3, 29)) AS age_n
),

artist_at_age AS (
  SELECT
    subs.artist_id,
    al.age_n,
    DATE_ADD(subs.first_plan_started_at, INTERVAL al.age_n MONTH) AS age_milestone_date,
    subs.last_plan_ended_at,
    subs.churner
  FROM `datastudio-proxy.data_sources.artists_subs` subs
  CROSS JOIN age_levels al
  WHERE subs.language = 'de'
    AND subs.first_plan_started_at >= '2024-01-01'
    AND DATE_ADD(subs.first_plan_started_at, INTERVAL al.age_n MONTH)
        <= COALESCE(subs.last_plan_ended_at, CURRENT_DATE())
)

SELECT
  age_n,
  COUNT(*)                                                                        AS nb_artists,
  COUNTIF(churner = 1 AND last_plan_ended_at
      BETWEEN age_milestone_date AND DATE_ADD(age_milestone_date, INTERVAL 30 DAY)) AS churners_30d,
  COUNTIF(churner = 1 AND last_plan_ended_at
      BETWEEN age_milestone_date AND DATE_ADD(age_milestone_date, INTERVAL 60 DAY)) AS churners_60d,
  COUNTIF(churner = 1 AND last_plan_ended_at
      BETWEEN age_milestone_date AND DATE_ADD(age_milestone_date, INTERVAL 90 DAY)) AS churners_90d
FROM artist_at_age
GROUP BY age_n
ORDER BY age_n
