with plan_dedup as (
  select distinct
    run_date,
    stripe_customer_id,
    id,
    level,
    frequency,
    stripe_status,
    created_at,
    current_period_start
  from `singulart-data.tech.artists_plans_audit_daily`
  where stripe_customer_id is not null
),

-- a customer can have several subscription rows on the same run_date
-- (current + historical); prefer the active one, else the most recently started
plan_ranked as (
  select
    *,
    row_number() over (
      partition by stripe_customer_id, run_date
      order by
        case when stripe_status = 'active' then 0 else 1 end,
        current_period_start desc,
        created_at desc
    ) as rn
  from plan_dedup
),

plan_at_batch as (
  select
    stripe_customer_id,
    run_date as batch_date,
    level as plan_level,
    frequency
  from plan_ranked
  where rn = 1
),

first_plan as (
  select
    stripe_customer_id,
    min(created_at) as first_plan_created_at
  from `singulart-data.tech.artists_plans_audit_daily`
  where stripe_customer_id is not null
  group by stripe_customer_id
)

select
  pi.amount,
  pi.customer_id,
  date(pi.created) as date_created,
  date(pi.batch_timestamp) as batch_date,
  payment_method_types,
  product_name,
  pab.plan_level,
  pab.frequency,
  case when aa.last_sale_at is not null then 'yes' else 'no' end as seller_tag,
  date_diff(date(pi.batch_timestamp), date(fp.first_plan_created_at), month) as age_in_months_since_first_plan
from `singulart-data.stripe.payment_intents` pi
inner join `singulart-data.stripe.payment_intent_line_items` piil on piil.payment_intent_id = pi.id
left join plan_at_batch pab on pab.stripe_customer_id = pi.customer_id and pab.batch_date = date(pi.batch_timestamp)
left join first_plan fp on fp.stripe_customer_id = pi.customer_id
left join `singulart-data.connected_sheets.all_artists` aa on aa.stripe_customer_id = pi.customer_id
where lower(product_name) in ('expert feedback')
