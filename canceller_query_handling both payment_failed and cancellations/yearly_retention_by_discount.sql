-- Yearly subscription retention by discount status
-- Year 1  = months 0–12 from sub creation  |  Year 2 = after the 12-month mark
-- Renewal = normal (new billing period >= 1 year after creation)
--           OR win-back (same artist created a new sub within 14 days of the old sub ending)
-- Discount source: subscription_items (primary) + subscriptions.discount_start (fallback)
-- MRR > 100 filter applied for consistency with other canceller queries

with

-- ── Discount lookup ────────────────────────────────────────────────────────

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

sub_discounted_batches as (
  select distinct
    si.subscription_id,
    date(si.batch_timestamp) as batch_date
  from `singulart-data.stripe.subscription_items` si
  inner join undup_discounts d on d.id = si.discounts
  inner join undup_coupons   c on c.id = d.coupon_id
),

-- ── Subscription spine ─────────────────────────────────────────────────────

sgt_artists_plans as (
  select stripe_subscription_id, artist_id, frequency, level
  from `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  qualify row_number() over(partition by stripe_subscription_id order by current_period_start desc) = 1
),

mrr as (
  select subscription_id
  from `singulart-data.sfa_acquisition.artists_mrr_changes`
  where event_type = 'ACTIVE_START'
    and mrr_change_in_eur > 100
  qualify row_number() over(partition by subscription_id order by event_timestamp desc) = 1
),

-- One row per eligible yearly subscription (created >= 1 year ago)
sub_spine as (
  select
    sub.id,
    sap.artist_id,
    date(sub.created)                                                as sub_created,
    date(sub.discount_start)                                         as sub_discount_start,
    date(sub.discount_end)                                           as sub_discount_end,
    max(date(sub.current_period_start))                              as max_period_start,
    -- End date = when the subscription actually lost access (for win-back window)
    max(coalesce(date(sub.ended_at), date(sub.cancel_at), date(sub.current_period_end))) as sub_end_date
  from `singulart-data.stripe.subscriptions` sub
  inner join sgt_artists_plans sap on sap.stripe_subscription_id = sub.id
  inner join mrr                    on mrr.subscription_id        = sub.id
  where sap.frequency   = 'year'
    and sap.artist_id   is not null
    and date(sub.created) <= date_sub(current_date(), interval 1 year)
  group by 1, 2, 3, 4, 5
),

-- All subscriptions (any frequency) used to find win-back new subscriptions
all_subs as (
  select
    sub.id,
    sap.artist_id,
    date(sub.created) as sub_created
  from `singulart-data.stripe.subscriptions` sub
  inner join sgt_artists_plans sap on sap.stripe_subscription_id = sub.id
  inner join `singulart-data.connected_sheets.all_artists` aa on aa.artist_id = sap.artist_id
  where sap.artist_id is not null and aa.online >= '2025-01-01'
  qualify row_number() over(partition by sub.id order by sub.batch_timestamp desc) = 1
),

-- Win-back: same artist opened a new sub within 14 days of the old sub ending
-- Also capture whether that new sub had an active discount (for Y2 discount flag)
win_back as (
  select
    ss.id                                                              as original_sub_id,
    max(case when sdb.subscription_id is not null then 1 else 0 end)  as new_sub_has_discount
  from sub_spine ss
  join all_subs new_s
    on  new_s.artist_id   = ss.artist_id
    and new_s.id         <> ss.id
    and new_s.sub_created between ss.sub_end_date
                               and date_add(ss.sub_end_date, interval 14 day)
  left join sub_discounted_batches sdb on sdb.subscription_id = new_s.id
  group by ss.id
),

-- Per subscription: renewal + discount flags
per_sub as (
  select
    ss.id,
    ss.artist_id,
    ss.sub_created,

    -- Renewed via normal billing cycle OR win-back within 14 days
    case when ss.max_period_start >= date_add(ss.sub_created, interval 1 year)
              or wb.original_sub_id is not null
         then 1 else 0
    end as renewed,

    -- Year 1 discount: subscription_items batch in Y1 OR subscriptions.discount_start in Y1
    case when
      max(case when sdb.batch_date < date_add(ss.sub_created, interval 1 year) then 1 else 0 end) = 1
      or (ss.sub_discount_start is not null
          and ss.sub_discount_start < date_add(ss.sub_created, interval 1 year))
    then 1 else 0 end as discount_year1,

    -- Year 2 discount: subscription_items batch in Y2, fallback from subscriptions, OR win-back new sub had discount
    case when
      max(case when sdb.batch_date >= date_add(ss.sub_created, interval 1 year) then 1 else 0 end) = 1
      or (ss.sub_discount_start is not null
          and ss.sub_discount_start >= date_add(ss.sub_created, interval 1 year))
      or coalesce(wb.new_sub_has_discount, 0) = 1
    then 1 else 0 end as discount_year2

  from sub_spine ss
  left join sub_discounted_batches sdb on sdb.subscription_id = ss.id
  left join win_back wb               on wb.original_sub_id   = ss.id
  group by ss.id, ss.artist_id, ss.sub_created, ss.max_period_start,
           ss.sub_discount_start, ss.sub_discount_end, wb.original_sub_id, wb.new_sub_has_discount
),

-- Total eligible per Y1 discount group (denominator for retention rate)
totals as (
  select
    discount_year1,
    count(*) as total_in_group
  from per_sub
  group by discount_year1
)

-- ── Output: 4 rows (renewed only, rate vs. full Y1 cohort) ────────────────
select
  case when ps.discount_year1 = 1 then 'Y1 discounted'        else 'Y1 not discounted'       end as y1_discount,
  case when ps.discount_year2 = 1 then 'Renewed with discount' else 'Renewed without discount' end as renewal_type,
  count(*)                                                  as renewed_count,
  any_value(t.total_in_group)                               as total_eligible,
  round(count(*) / any_value(t.total_in_group) * 100, 2)   as retention_rate_pct
from per_sub ps
join totals t on t.discount_year1 = ps.discount_year1
where ps.renewed = 1
group by ps.discount_year1, ps.discount_year2
order by ps.discount_year1 desc, ps.discount_year2 desc
