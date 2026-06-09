WITH first_plan_per_artist as (
select
artist_id
,date(created_at) as created_at
,row_number() over(partition by artist_id order by created_at asc) rn
from `singulart-db-to-bigquery.singulartdb.sgt_artists_plans` sap),

first_plan_per_stripe_customer_id as (
select
sap.stripe_customer_id
,date(first_plan_per_artist.created_at) as first_plan_date
from first_plan_per_artist
left join `singulart-db-to-bigquery.singulartdb.sgt_artists_plans` sap on sap.artist_id = first_plan_per_artist.artist_id
where rn=1 and sap.stripe_customer_id is not null
),

stripe_customer_artist_id as (
select distinct
stripe_customer_id,
artist_id
from `singulart-db-to-bigquery.singulartdb.sgt_artists_plans` sap
where stripe_customer_id is not null),

ts_grouped_sub_item_events AS (
SELECT
local_event_timestamp,
customer_id,
sum(round(sice.mrr_change*cr.rate,2)) AS mrr_change
FROM `singulart-data.stripe.subscription_item_change_events` sice
INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies` c1 ON c1.currency = UPPER(sice.currency)
INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies_rates` cr ON cr.base_id = c1.id AND cr.target_id = 43
GROUP BY
1,
2
),
ts_grouped_sub_item_events_with_mrr AS (
SELECT
*,
date_trunc(
date(local_event_timestamp), day
) AS local_event_date,
-- Stripe defines an "active subscriber" as a customer with non-zero MRR.
-- Therefore instead of summing up event_type to get subscription count (and its diff),
-- We count the amount of revenue on each customer instead and later check its movement from / to zero
sum(mrr_change) over (
PARTITION by customer_id
ORDER BY
local_event_timestamp ASC
) AS mrr,
-- We count the # of times MRR has actually changed, and use nullif to ignore events that do not impact MRR
-- Otherwise we may confuse between new vs. reactivation
count(nullif(mrr_change, 0)) over (
PARTITION by customer_id
ORDER BY
local_event_timestamp ASC
) AS mrr_change_count
FROM
ts_grouped_sub_item_events
),
ts_grouped_sub_item_events_with_previous_mrr AS (
SELECT
*,
coalesce(
last_value(mrr) OVER (PARTITION by customer_id ORDER BY local_event_timestamp ASC ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
0
) AS previous_mrr
FROM
ts_grouped_sub_item_events_with_mrr
)
SELECT
local_event_date as event_date,
date_trunc(local_event_date, month) as event_month,
scai.artist_id as artist_id,
sa.email,
customer_id,
round(mrr_change/100,2) mrr_change,
round(mrr/100,2) as mrr,
first_plan_per_stripe_customer_id.first_plan_date as first_plan_created_at,
case
when first_plan_per_stripe_customer_id.first_plan_date is null then 'Unknown'
when date_diff(local_event_date, first_plan_per_stripe_customer_id.first_plan_date, day) <= 20 then 'New Artist'
when date_diff(local_event_date, first_plan_per_stripe_customer_id.first_plan_date, day) > 20 then 'Reactivation'
end as event_type,
language,
CASE
WHEN mrr = 0 AND previous_mrr > 0 THEN 'ACTIVE_END'
WHEN mrr > 0 AND previous_mrr = 0 AND mrr_change_count = 1 THEN 'ACTIVE_START'
WHEN mrr > 0 AND previous_mrr = 0 AND mrr_change_count > 1 THEN 'REACTIVATE'
WHEN mrr > previous_mrr THEN 'ACTIVE_UPGRADE'
WHEN mrr < previous_mrr THEN 'ACTIVE_DOWNGRADE'
ELSE NULL
END AS cus_event_type
FROM ts_grouped_sub_item_events_with_previous_mrr sq
LEFT JOIN stripe_customer_artist_id scai on scai.stripe_customer_id = sq.customer_id
LEFT JOIN first_plan_per_stripe_customer_id on first_plan_per_stripe_customer_id.stripe_customer_id = sq.customer_id
LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_artists` sa on sa.id = scai.artist_id
WHERE mrr_change_count = 1