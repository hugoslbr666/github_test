-- Cancellation rate: subscriptions that cancelled *while* discounted vs. not
-- "discounted canceller" = cancellation_event fired on a batch where subscription_items showed an active discount
-- MRR > 100 filter applied to match the rest of the canceller suite

with

-- ── Discount lookup tables ─────────────────────────────────────────────────

undup_discounts as (
  select * except(rn)
  from (
    select *, row_number() over(partition by id order by batch_timestamp desc) as rn
    from `singulart-data.stripe.discounts`
  )
  where rn = 1
),

undup_coupons as (
  select * except(rn)
  from (
    select *, row_number() over(partition by id order by batch_timestamp desc) as rn
    from `singulart-data.stripe.coupons`
  )
  where rn = 1
),

-- (subscription_id, batch_date) pairs where a discount was actively applied
-- INNER JOINs ensure si.discounts resolves to a real discount+coupon record
sub_discounted_batches as (
  select distinct
    si.subscription_id,
    date(si.batch_timestamp) as batch_date,
    c.percent_off,
    c.name                   as coupon_name
  from `singulart-data.stripe.subscription_items` si
  inner join undup_discounts d on d.id = si.discounts
  inner join undup_coupons   c on c.id = d.coupon_id
),

-- ── Subscription spine ────────────────────────────────────────────────────

sgt_artists_plans as (
  select stripe_subscription_id, artist_id, frequency, level
  from `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  qualify row_number() over(partition by stripe_subscription_id order by current_period_start desc) = 1
),

sq as (
  select
    sub.id,
    sub.status,
    sap.artist_id,
    sap.level,
    sap.frequency,
    date(sub.canceled_at)          as canceled_at,
    date(sub.cancel_at)            as cancel_at,
    date(sub.current_period_end)   as current_period_end,
    timestamp(sub.batch_timestamp) as data_batch_timestamp,
    sub.cancellation_details_reason,
    date(sub.discount_start)       as sub_discount_start,
    date(sub.discount_end)         as sub_discount_end,
    date(sub.created)              as sub_created,
    row_number() over(partition by sub.id order by sub.batch_timestamp asc) as rn
  from `singulart-data.stripe.subscriptions` sub
  left join sgt_artists_plans sap on sap.stripe_subscription_id = sub.id
),

mrr as (
  select subscription_id
  from `singulart-data.sfa_acquisition.artists_mrr_changes`
  where event_type = 'ACTIVE_START'
    and mrr_change_in_eur > 100
  qualify row_number() over(partition by subscription_id order by event_timestamp desc) = 1
),

-- ── Cancellation event detection (same logic as canceller_query_280526) ───

w as (
  select
    *,
    lag(canceled_at) over(partition by id order by rn) as prev_cancelled_at,
    lag(cancel_at)   over(partition by id order by rn) as prev_cancel_at,
    case when rn = 1 then 'subscription_creation'
         else lag(status) over(partition by id order by rn)
    end as prev_status
  from sq
),

w1 as (
  select
    * except(prev_cancelled_at, prev_cancel_at, prev_status),
    lag(canceled_at) over(partition by id order by rn) as prev_cancelled_at,
    lag(cancel_at)   over(partition by id order by rn) as prev_cancel_at,
    case when rn = 1 then 'subscription_creation'
         else lag(status) over(partition by id order by rn)
    end as prev_status
  from w
  where not (status = 'past_due' and prev_status = 'past_due')
),

events as (
  select
    w1.id,
    w1.artist_id,
    w1.level,
    w1.frequency,
    w1.sub_created,
    date_trunc(w1.sub_created, month) as cohort_month,
    -- Was a discount active on this batch? subscription_items is primary, subscriptions.discount_start is fallback
    case
      when sdb.subscription_id is not null then 1
      when w1.sub_discount_start is not null
           and date(w1.data_batch_timestamp) >= w1.sub_discount_start
           and (w1.sub_discount_end is null or date(w1.data_batch_timestamp) <= w1.sub_discount_end) then 1
      else 0
    end as discounted_on_this_batch,
    sdb.percent_off,
    sdb.coupon_name,
    case when a_a.last_sale_at is null then 'non seller' else 'seller' end as seller_tag,
    -- Voluntary cancellation event
    case
      when w1.canceled_at is not null and w1.status = 'active'
           and w1.cancellation_details_reason not in ('payment_failed')
           and coalesce(w1.prev_cancelled_at, w1.prev_cancel_at) is null     then 1
      when w1.canceled_at is not null and w1.status = 'canceled'
           and w1.cancellation_details_reason not in ('payment_failed')
           and w1.prev_status = 'active'
           and coalesce(w1.prev_cancelled_at, w1.prev_cancel_at) is null     then 1
      when w1.status not in ('canceled')
           and w1.cancellation_details_reason = 'cancellation_requested'
           and coalesce(w1.prev_cancelled_at, w1.prev_cancel_at) is null     then 1
      else 0
    end as cancellation_event
  from w1
  inner join mrr on mrr.subscription_id = w1.id
  left join sub_discounted_batches sdb
    on  sdb.subscription_id = w1.id
    and sdb.batch_date       = date(w1.data_batch_timestamp)
  left join `singulart-data.connected_sheets.all_artists` a_a on a_a.artist_id = w1.artist_id
  where w1.artist_id is not null and online_at >= '2025-01-01'
),

-- One row per subscription
per_subscription as (
  select
    id,
    any_value(artist_id)                                                           as artist_id,
    any_value(level)                                                               as level,
    any_value(frequency)                                                           as frequency,
    any_value(sub_created)                                                         as sub_created,
    any_value(cohort_month)                                                        as cohort_month,
    -- "cancelled while discounted" = cancellation event fired on a discounted batch
    max(case when cancellation_event = 1 and discounted_on_this_batch = 1 then 1 else 0 end) as cancelled_while_discounted,
    -- Also track whether subscription ever had a discount (for context)
    max(discounted_on_this_batch)                                                  as ever_discounted,
    max(cancellation_event)                                                        as cancelled,
    any_value(if(cancellation_event = 1 and discounted_on_this_batch = 1, percent_off, null)) as discount_pct_at_cancellation,
    any_value(if(cancellation_event = 1 and discounted_on_this_batch = 1, coupon_name, null)) as coupon_at_cancellation,
    any_value(seller_tag)                                                          as seller_tag
  from events
  group by id
)

select
  case when ever_discounted = 1 then 'With discount' else 'Without discount' end as discount_group,
  frequency,
  seller_tag,
  count(*)                                                                        as total_subscriptions,
  case
    when ever_discounted = 1 then countif(cancelled_while_discounted = 1)
    else                          countif(cancelled = 1)
  end                                                                             as cancellations,
  round(
    case
      when ever_discounted = 1 then countif(cancelled_while_discounted = 1)
      else                          countif(cancelled = 1)
    end / count(*) * 100, 2)                                                     as cancellation_rate_pct
from per_subscription
group by ever_discounted, frequency, seller_tag
order by ever_discounted desc, frequency, seller_tag
