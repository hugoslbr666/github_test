select *
from (
select
s.id,
sap.artist_id,
email,
sap.level,
sap.frequency,
date(s.canceled_at) as stripe_cancellation_request_date,
date(s.cancel_at) as stripe_cancellation_due_date,
s.cancel_at_period_end,
--s.default_payment_method_id,
tpm.type payment_type,
tpm.link_email,
row_number() over(partition by s.id order by s.batch_timestamp desc) as rn_desc
from `singulart-data.stripe.subscriptions` s
left join `singulart-db-to-bigquery.singulartdb.sgt_artists_plans` sap on sap.stripe_subscription_id = s.id
left join `singulart-data.connected_sheets.all_artists` a_a on a_a.artist_id = sap.artist_id
left join `singulart-datasandbox.hugo.temp_payment_methods` tpm on tpm.id = s.default_payment_method_id
where cancel_at = canceled_at 
) where rn_desc = 1
order by stripe_cancellation_due_date asc