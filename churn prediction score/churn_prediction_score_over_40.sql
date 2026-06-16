with hubspot_data as (
  select
    c.id as contact_id,
    c.property_email as email,
    c.property_singulart_artist_id as artist_id
  from `singulart-data.hubspot_stitch.contacts` c
),

base as (
  select
    cpsa.run_date,
    cpsa.contact_email,
    contact_id,
    aa.artist_id,
    churn_prediction_score,
    apad.level,
    apad.frequency,
    row_number() over(partition by aa.artist_id order by cpsa.run_date asc) as score_number
  from `singulart-data.sfa_acquisition.churn_predictor_score_audit` cpsa
  inner join hubspot_data on hubspot_data.email = cpsa.contact_email
  inner join `singulart-data.connected_sheets.all_artists` aa on aa.artist_id = hubspot_data.artist_id
  inner join `singulart-data.tech.artists_plans_audit_daily` apad
    on apad.artist_id = aa.artist_id
    and apad.run_date = cpsa.run_date
    and level in ('gold', 'platinum')
    and frequency in ('month')
    and (apad.ended_at is null or apad.ended_at > cpsa.run_date)
),

scored as (
  select
    *,
    min(case when churn_prediction_score >= 40 then run_date end) over (partition by artist_id) as first_date_gte_40
  from base
)

select
  run_date,
  count(distinct artist_id) as artists,
  count(distinct case when churn_prediction_score >= 40 then artist_id end) as artists_score_gte_40,
  count(distinct case when churn_prediction_score >= 40 and run_date = first_date_gte_40 then artist_id end) as new_artists_score_gte_40,
  count(distinct case when churn_prediction_score > 40 then artist_id end) as artists_score_gt_40,
  round(avg(churn_prediction_score), 2) as avg_score,
  min(churn_prediction_score) as min_score,
  APPROX_QUANTILES(churn_prediction_score, 100)[OFFSET(25)] as Q1,
  APPROX_QUANTILES(churn_prediction_score, 100)[OFFSET(50)] as median,
  APPROX_QUANTILES(churn_prediction_score, 100)[OFFSET(75)] as Q3,
  max(churn_prediction_score) as max_score
from scored
group by run_date
order by run_date desc
