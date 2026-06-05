select 
id subscription_id,
batch_timestamp,
canceled_at,
cancel_at,
cancellation_details_reason,
status
from `singulart-data.stripe.subscriptions`
where id = 'sub_1R8P8pAUiJ1239Lp4xhDa9ab'
order by batch_timestamp asc