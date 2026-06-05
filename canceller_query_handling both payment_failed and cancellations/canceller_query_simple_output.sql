--Simplest query

with

owners as (
  SELECT
  cast(id as INT64) as new_user_id,
  firstname,
  lastname,
  email
  FROM `singulart-data.hubspot_stitch.owners`
),

hubspot_data as (
  select
  timestamp(d.property_createdate.value) as create_tmstp,
  coalesce(
    timestamp(d.property_closedate.value),
    timestamp(lead(d.property_createdate.value)
      over(partition by REGEXP_EXTRACT(property_dealname.value, r'[\w\.-]+@[\w\.-]+\.\w+') order by timestamp(d.property_createdate.value) asc))
    ,current_timestamp()) as end_tmstp,
  date(d.property_createdate.value) as create_date,
  timestamp(d.property_createdate.value) as create_timestamp,
  coalesce(date(d.property_closedate.value),
  lead(date(d.property_createdate.value))
  over(partition by REGEXP_EXTRACT(property_dealname.value, r'[\w\.-]+@[\w\.-]+\.\w+') order by timestamp(d.property_createdate.value) asc)
  ,current_date()) AS end_date,
  dealid,
  property_dealname.value as deal_name,
  case
  when property_dealstage.value in ('244194161') then ('New Canceller')
  when property_dealstage.value in ('244194162','244194163','244194164','244194165') then ('Call Tried')
  when property_dealstage.value in ('244194169') then ('Called')
  when property_dealstage.value in ('244194166') then ('Closed Won')
  when property_dealstage.value in ('244194167') then ('Closed Lost')
  end as deal_stage,
  vid.value as deal_vid,
  coalesce(Singulart_Artist_ID,cast(c.property_singulart_artist_id as INT64)) as artist_id,
  c.id as vid,
  REGEXP_EXTRACT(property_dealname.value, r'([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})') AS deal_email,
  c.property_email as main_email,
  c.property_hs_additional_emails as additionnal_emails ,
  concat(owners.firstname,' ',owners.lastname) as care_agent,
  row_number() over(partition by c.property_email, date(d.property_createdate.value) order by timestamp(d.property_createdate.value) desc) as rn
  from `singulart-data.hubspot_stitch.deals` d
  left join unnest(d.associations.associatedvids) vid
  left join owners on owners.new_user_id = SAFE_CAST(d.property_hubspot_owner_id.value AS INT64)
  left join `singulart-data.hubspot_stitch.contacts` c on cast(c.id as string) = cast(vid.value as string)
  left join `singulart-datasandbox.hugo.temp_husbpot_contact_artist_id` thca on thca.Record_ID = vid.value
  where property_pipeline.value in ('142987873')
  order by dealid asc, d.property_createdate.value asc
),

mrr as (
  select subscription_id, mrr_change_in_eur as last_mrr
  from `singulart-data.sfa_acquisition.artists_mrr_changes`
  where event_type = 'ACTIVE_START'
  qualify row_number() over(partition by subscription_id order by event_timestamp desc) = 1
    and mrr_change_in_eur > 100
),

sgt_artists_plans as (
  select stripe_subscription_id, artist_id, frequency, level
  from `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  qualify row_number() over(partition by stripe_subscription_id order by current_period_start desc) = 1
),

customers as (
  select email, id, address_country as stripe_country
  from `singulart-data.stripe.customers`
  qualify row_number() over(partition by email, id order by created desc) = 1
),

-- One row per subscription batch: core event fields only
sq as (
  select
    sub.id, sub.customer_id, stripe_country, sub.status, sap.artist_id, customers.email,
    date(canceled_at)          as canceled_at,
    date(cancel_at)            as cancel_at,
    date(case when sub.status = 'past_due' then sub.batch_timestamp end) as payment_failed_at,
    date(sub.current_period_end)   as current_period_end,
    timestamp(sub.batch_timestamp) as data_batch_timestamp,
    sub.cancellation_details_reason,
    sap.frequency,
    sap.level,
    row_number() over(partition by sub.id order by sub.batch_timestamp asc) as rn
  from `singulart-data.stripe.subscriptions` sub
  left join customers         on customers.id = sub.customer_id
  left join sgt_artists_plans sap on sap.stripe_subscription_id = sub.id
),

-- Compute prev_* window columns over all batches
w as (
  select
    id, customer_id, stripe_country, status, artist_id, email,
    canceled_at, cancel_at, payment_failed_at, current_period_end,
    data_batch_timestamp, cancellation_details_reason, frequency, level, rn,
    lag(canceled_at) over(partition by id order by rn) as prev_cancelled_at,
    lag(cancel_at)   over(partition by id order by rn) as prev_cancel_at,
    case when rn = 1 then 'subscription_creation'
         else lag(status) over(partition by id order by rn)
    end as prev_status
  from sq
),

-- Filter consecutive past_due rows (keep when new cancellation appeared), recompute prev_* on filtered set
w1 as (
  select
    id, customer_id, stripe_country, status, artist_id, email,
    canceled_at, cancel_at, payment_failed_at, current_period_end,
    data_batch_timestamp, cancellation_details_reason, frequency, level, rn,
    lag(canceled_at) over(partition by id order by rn) as prev_cancelled_at,
    lag(cancel_at)   over(partition by id order by rn) as prev_cancel_at,
    case when rn = 1 then 'subscription_creation'
         else lag(status) over(partition by id order by rn)
    end as prev_status
  from w
  where not (status = 'past_due' and prev_status = 'past_due')
     or (canceled_at is not null and prev_cancelled_at is null)
     or (cancel_at   is not null and prev_cancel_at   is null)
),

-- Classify each row: event_type + event / due / resolved dates
processing as (
  select
    w1.id, w1.customer_id, w1.stripe_country, w1.status, w1.artist_id, w1.email,
    w1.rn,

    case
      when canceled_at is not null and w1.status = 'active'   and w1.cancellation_details_reason not in ('payment_failed') and coalesce(prev_cancelled_at, prev_cancel_at) is null then 'cancellation'
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason not in ('payment_failed') and w1.prev_status = 'active' and coalesce(prev_cancelled_at, prev_cancel_at) is null then 'cancellation'
      when w1.status not in ('canceled') and w1.cancellation_details_reason in ('cancellation_requested') and coalesce(prev_cancelled_at, prev_cancel_at) is null then 'cancellation'
      when coalesce(canceled_at, cancel_at) is null and coalesce(prev_cancelled_at, prev_cancel_at) is not null then 'cancellation'
      when w1.status = 'past_due'  and w1.prev_status <> 'past_due' then 'payment_failed'
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason in ('payment_failed') and w1.prev_status = 'active' and prev_cancelled_at is null then 'payment_failed'
      when canceled_at is not null and w1.status = 'past_due' and prev_cancelled_at is null then 'payment_failed'
      when w1.status = 'active' and w1.prev_status = 'past_due' then 'payment_failed'
    end as event_type,

    case
      when canceled_at is not null and w1.status = 'active'   and w1.cancellation_details_reason not in ('payment_failed') and coalesce(prev_cancelled_at, prev_cancel_at) is null then timestamp(w1.canceled_at)
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason not in ('payment_failed') and w1.prev_status = 'active' and coalesce(prev_cancelled_at, prev_cancel_at) is null then timestamp(w1.canceled_at)
      when w1.status not in ('canceled') and w1.cancellation_details_reason in ('cancellation_requested') and coalesce(prev_cancelled_at, prev_cancel_at) is null then coalesce(timestamp(w1.canceled_at), w1.data_batch_timestamp)
      when coalesce(canceled_at, cancel_at) is null and coalesce(prev_cancelled_at, prev_cancel_at) is not null then coalesce(timestamp(prev_cancelled_at), lag(w1.data_batch_timestamp) over(partition by w1.id order by w1.rn))
      when w1.status = 'past_due'  and w1.prev_status <> 'past_due' then timestamp(w1.payment_failed_at)
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason in ('payment_failed') and w1.prev_status = 'active' and prev_cancelled_at is null then timestamp(w1.payment_failed_at)
      when canceled_at is not null and w1.status = 'past_due' and prev_cancelled_at is null then timestamp(w1.payment_failed_at)
      when w1.status = 'active' and w1.prev_status = 'past_due' then
        timestamp(max(case when w1.status = 'past_due' and w1.prev_status <> 'past_due' then w1.payment_failed_at end)
          over(partition by w1.id order by w1.rn rows between unbounded preceding and 1 preceding))
    end as event_date,

    case
      when canceled_at is not null and w1.status = 'active'   and w1.cancellation_details_reason not in ('payment_failed') and coalesce(prev_cancelled_at, prev_cancel_at) is null then coalesce(w1.cancel_at, w1.current_period_end)
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason not in ('payment_failed') and w1.prev_status = 'active' and coalesce(prev_cancelled_at, prev_cancel_at) is null then coalesce(w1.cancel_at, w1.current_period_end)
      when w1.status not in ('canceled') and w1.cancellation_details_reason in ('cancellation_requested') and coalesce(prev_cancelled_at, prev_cancel_at) is null then coalesce(w1.cancel_at, w1.current_period_end)
      when coalesce(canceled_at, cancel_at) is null and coalesce(prev_cancelled_at, prev_cancel_at) is not null then coalesce(prev_cancel_at, lag(w1.current_period_end) over(partition by w1.id order by w1.rn))
      when w1.status = 'past_due'  and w1.prev_status <> 'past_due' then date_add(w1.payment_failed_at, interval 14 day)
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason in ('payment_failed') and w1.prev_status = 'active' and prev_cancelled_at is null then date_add(w1.payment_failed_at, interval 14 day)
      when canceled_at is not null and w1.status = 'past_due' and prev_cancelled_at is null then date_add(w1.payment_failed_at, interval 14 day)
      when w1.status = 'active' and w1.prev_status = 'past_due' then
        date_add(max(case when w1.status = 'past_due' and w1.prev_status <> 'past_due' then w1.payment_failed_at end)
          over(partition by w1.id order by w1.rn rows between unbounded preceding and 1 preceding), interval 14 day)
    end as due_date,

    case
      when coalesce(canceled_at, cancel_at) is null and coalesce(prev_cancelled_at, prev_cancel_at) is not null then w1.data_batch_timestamp
      when w1.status = 'active' and w1.prev_status = 'past_due' then w1.data_batch_timestamp
    end as resolved_date,

    w1.frequency as frequency_computed,
    level as plan_level,
    case when a_a.last_sale_at is null then 'no' else 'yes' end as seller_tag,
    a_a.country  as sgt_country,
    a_a.language

  from w1
  left join `singulart-data.connected_sheets.all_artists` a_a on a_a.artist_id = w1.artist_id
),

-- One-row-per-event: keep resolution rows + genuinely open events
final as (
  select
    id, customer_id, stripe_country, status, artist_id, email,
    event_type,
    date(event_date)    as event_date,
    due_date,
    date(resolved_date) as resolved_date,
    frequency_computed,plan_level, seller_tag, sgt_country, language,
    max(resolved_date) over(
      partition by id, event_type
      order by rn
      rows between 1 following and unbounded following
    ) as next_resolution_date
  from processing
)

select
  current_date as run_date,
  final.id, final.customer_id, final.stripe_country, final.status, final.artist_id, final.email,
  final.event_type, final.event_date, final.due_date, final.resolved_date,
  date_trunc(final.event_date, month) AS event_month, date_trunc(final.due_date, month) AS due_date_month,
  date_trunc(final.resolved_date, month) resolved_month,
  final.frequency_computed, final.seller_tag, final.sgt_country, final.language,
  any_value(ifnull(coalesce(cdmc.deal_owner, care_agent),'-')) as agent,
  mrr.last_mrr / 100 as mrr, plan_level
from final
left join mrr on mrr.subscription_id = final.id
left join `singulart-datasandbox.hugo.canceller_deal_manual_corrections` cdmc on cdmc.artist_id = final.artist_id and date(cancellation_due_date) = date(final.due_date)
left join hubspot_data on hubspot_data.artist_id = final.artist_id 
  and hubspot_data.create_date >= final.event_date and hubspot_data.create_date <= final.due_date
  and hubspot_data.rn = 1
where final.artist_id is not null
  and final.event_type is not null
  and (final.resolved_date is not null or final.next_resolution_date is null)
group by ALL
order by event_date desc