with sq as (
  select
  property_email,
  cast(property_singulart_artist_id as INT64) artist_id,
  tp.email_sent_on,
  tp.webinar_date,
  tp.attented
  from `singulart-data.hubspot_stitch.contacts` c
  inner join `singulart-datasandbox.hugo.temp_webinar_artists_de` as tp on tp.artist_email = c.property_email
  )

select
subs.artist_id,
email_sent_on,
webinar_date,
attented,
frequency,
first_plan_started_at,
last_plan_started_at,
last_plan_ended_at,
last_plan_level,
--cohort,
age,
cohort_age,
seller,
DATE_DIFF(sq.email_sent_on, subs.first_plan_started_at, MONTH) as age_at_email_sent,
IF(subs.churner = 1 AND subs.last_plan_ended_at > sq.email_sent_on,
  DATE_DIFF(subs.last_plan_ended_at, sq.email_sent_on, DAY),
  NULL) as days_to_churn_after_email,
IF(subs.churner = 1 AND subs.last_plan_ended_at > sq.webinar_date,
  DATE_DIFF(subs.last_plan_ended_at, sq.webinar_date, DAY),
  NULL) as days_to_churn_after_webinar,
count(subs.artist_id) nb_artists,
sum(churner) nb_churners
from `datastudio-proxy.data_sources.artists_subs` subs
INNER JOIN sq on sq.artist_id = subs.artist_id
group by all