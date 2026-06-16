with hubspot_data as (
select
c.id as contact_id,
c.property_email as email,
c.property_singulart_artist_id as artist_id
from `singulart-data.hubspot_stitch.contacts` c 
)

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
inner join `singulart-data.tech.artists_plans_audit_daily` apad on apad.artist_id = aa.artist_id and apad.run_date = cpsa.run_date and level not in ('vip','selected')