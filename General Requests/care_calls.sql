-- care call query

with
owners as (
  select
    cast(id as int64) as new_user_id,
    firstname,
    lastname,
    email
  from `singulart-data.hubspot_stitch.owners`
),

calls as (
  select
    date(date_trunc(d.property_createdate.value, month)) as create_month,
    date(date_trunc(d.property_closedate.value, month)) as end_month,
    date(d.property_createdate.value) as create_date,
    date(d.property_closedate.value) as end_date,
    dealid,
    property_dealname.value as deal_name,
    case
      when property_dealstage.value in ('1333134002') then 'New Deal'
      when property_dealstage.value in ('1339506947','1339506948','1339506949') then 'Call Tried'
      when property_dealstage.value in ('1333134003') then 'Called'
      when property_dealstage.value in ('1339797632') then 'Archived'
    end as deal_stage,
    vid.value as deal_vid,
    coalesce(thca.Singulart_Artist_ID, cast(c.property_singulart_artist_id as int64)) as artist_id,
    concat(owners.firstname, ' ', owners.lastname) as care_agent,
    country as artist_country,
    row_number() over(partition by c.property_email, date(d.property_createdate.value) order by timestamp(d.property_createdate.value) desc) as rn
  from `singulart-data.hubspot_stitch.deals` d
  left join unnest(d.associations.associatedvids) vid
  left join owners on owners.new_user_id = safe_cast(d.property_hubspot_owner_id.value as int64)
  left join `singulart-data.hubspot_stitch.contacts` c on cast(c.id as string) = cast(vid.value as string)
  left join `singulart-datasandbox.hugo.temp_husbpot_contact_artist_id` thca on thca.Record_ID = vid.value
  left join `singulart-data.connected_sheets.all_artists` a_a on a_a.artist_id = coalesce(thca.Singulart_Artist_ID, cast(c.property_singulart_artist_id as int64))
  where property_pipeline.value in ('886209826')
    and date(d.property_createdate.value) >= '2026-04-01'
),

-- Most recent plan snapshot on or before the call date
plan_at_call as (
  select
    ca.dealid,
    ap.level as plan_level,
    ap.frequency
  from calls ca
  left join `singulart-data.tech.artists_plans_audit_daily` ap
    on ap.artist_id = ca.artist_id
    and ap.run_date <= ca.create_date
  qualify row_number() over(partition by ca.dealid order by ap.run_date desc) = 1
),

-- Latest cancellation date after the call (from Stripe)
cancellations as (
  select
    ca.dealid,
    max(date(s.canceled_at)) as latest_cancellation_date
  from calls ca
  left join `singulart-db-to-bigquery.singulartdb.sgt_artists_plans` sap 
    on sap.artist_id = ca.artist_id
  left join `singulart-data.stripe.subscriptions` s
    on s.id = sap.stripe_subscription_id
    and s.canceled_at is not null
    and date(s.canceled_at) > ca.create_date
  group by ca.dealid
),

-- ended_at from the most recent artist plan
sub_ended as (
  select
    ca.dealid,
    date(ap.ended_at) as subscription_ended_at
  from calls ca
  left join `singulart-db-to-bigquery.singulartdb.sgt_artists_plans` ap
    on ap.artist_id = ca.artist_id
  qualify row_number() over(partition by ca.dealid order by ap.created_at desc) = 1
)

select
  ca.*,
  pac.plan_level as plan_level_at_call,
  pac.frequency as frequency_at_call,
  can.latest_cancellation_date,
  if(can.latest_cancellation_date is not null, 1, 0) as canceller,
  date_diff(can.latest_cancellation_date, ca.create_date, day) as days_to_cancel,
  se.subscription_ended_at,
  if(se.subscription_ended_at is not null, 1, 0) as churner,
  date_diff(se.subscription_ended_at, ca.create_date, day) as days_to_churn
from calls ca
left join plan_at_call pac on pac.dealid = ca.dealid
left join cancellations can on can.dealid = ca.dealid
left join sub_ended se on se.dealid = ca.dealid
order by ca.dealid asc, ca.create_date asc
