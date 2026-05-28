with
--Hubspot Block
mrr as (
select
* except(rn)
from
(select
--artist_id,
subscription_id,
mrr_change_in_eur as last_mrr,
row_number() over(partition by subscription_id order by event_timestamp desc) rn
from `singulart-data.sfa_acquisition.artists_mrr_changes`
where event_type in ('ACTIVE_START'))
where rn = 1
and last_mrr > 100
),

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
order by dealid asc, d.property_createdate.value asc),

--End of Hubspot Block

--Start of Stripe Block

prices as (
  select
  *,
  row_number() over(partition by id order by batch_timestamp desc) as rn
  from `singulart-data.stripe.prices`
  ),

  products as (
  select
  id,
  name as plan_level,
  created,
  row_number() over(partition by id order by batch_timestamp desc) as rn
  from `singulart-data.stripe.products`
  ),

  sgt_artists_plans as (
  select
  *, 
  row_number() over(partition by stripe_subscription_id order by current_period_start desc) as rn
  from `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  ),

  customers as (
  select
  email,
  created,
  id,
  address_country as stripe_country,
  row_number() over(partition by email,id order by created desc) rn
  from `singulart-data.stripe.customers`
  group by 1,2,3,4
  ),

sq as (
select
sub.id,
sub.customer_id,
stripe_country,
sub.status,
sap.artist_id,
customers.email,
date(sub.created) as created,
date(sub.ended_at) as ended_at,
date(sub.start_date) as start_date,
date(sub.current_period_start) as current_period_start,
date(sub.current_period_end) as current_period_end,
date(sub.discount_start) as discount_start,
date(sub.discount_end) as discount_end,
date(canceled_at) as canceled_at,
date(cancel_at) as cancel_at,
date(case when sub.status in ('past_due') then sub.batch_timestamp else null end) as payment_failed_at,
cancel_at_period_end,
timestamp(sub.batch_timestamp) as data_batch_timestamp,
date(sub.batch_timestamp) as data_batch_date,
sub.cancellation_details_reason,
sap.level,
sap.frequency,
--lower(REPLACE(products.plan_level, 'SINGULART ', '')) AS plan_level,
row_number() over(partition by sub.id order by sub.batch_timestamp asc) as rn
from `singulart-data.stripe.subscriptions` sub
left join customers on customers.id = sub.customer_id and customers.rn = 1
--left join prices on prices.id = sub.price_id and prices.rn = 1
--left join products on products.id = prices.product_id and prices.rn = 1
left join sgt_artists_plans sap on sap.stripe_subscription_id = sub.id and sap.rn = 1
),

-- INNER LAYER: compute all window functions here
w as (
select
* ,
lag(canceled_at) over(partition by id order by rn) as prev_cancelled_at,
lag(cancel_at) over(partition by id order by rn) as prev_cancel_at,
case when rn = 1 then 'subscription_creation'
else lag(status) over(partition by id order by rn) end as prev_status
from sq
),

w1 as (
select
*
from w
where not (status='past_due' and prev_status ='past_due')
),

-- OUTER LAYER: safely reference prev_cancelled_at and prev_status
processing AS (
select
w1.* except(frequency, cancellation_details_reason),
case when
prev_status = 'past_due' then lag(coalesce(w1.payment_failed_at,data_batch_date)) over(partition by w1.id order by w1.rn) else null end as prev_payment_failed_at,
lag(w1.current_period_end) over(partition by w1.id order by w1.rn)
as prev_period_end,
/*
-- activation issue
  case when w1.status like '%incomplete%' and prev_status = 'subscription_creation' then 1 else 0 end as activation_issue,
  */
  -- recovery from activation issue
  /*case
  when w1.status = 'active' and prev_status like '%incomplete%' then 1
  else 0
  end as recovered_from_activation_issue,
  */
-- cancellation click
case
  when canceled_at is not null and w1.status = 'active' and cancellation_details_reason not in ('payment_failed') then 1
  when canceled_at is not null and w1.status = 'canceled' and cancellation_details_reason not in ('payment_failed') and w1.prev_status = 'active' then 1
  else 0 end
as is_canceller,
-- new cancellation event
case
  when canceled_at is not null and w1.status = 'active' and cancellation_details_reason not in ('payment_failed') and (prev_cancelled_at is null) then 1
  when canceled_at is not null and w1.status = 'canceled' and cancellation_details_reason not in ('payment_failed') and w1.prev_status = 'active' and (prev_cancelled_at is null) then 1
else 0 end
as cancellation_event,

-- canceller retention event
case
  when canceled_at is null and prev_cancelled_at is not null then 1
  else 0 end
as canceller_retained,

-- late payment flag
case
  when w1.status = 'past_due' and w1.prev_status <> 'past_due' then 1
  when canceled_at is not null and w1.status = 'canceled' and cancellation_details_reason in ('payment_failed') and w1.prev_status = 'active' and (prev_cancelled_at is null) then 1
  when canceled_at is not null and w1.status = 'past_due' and (prev_cancelled_at is null) then 1
else 0 end
as is_past_due,

-- recovery from late payment
case when w1.status = 'active' and prev_status = 'past_due' then 1 else 0 end as recovered_from_past_due,

--cancel or payment failed event
case
when canceled_at is not null and w1.status = 'active' and cancellation_details_reason not in ('payment_failed') and (prev_cancelled_at is null) then 1
when canceled_at is not null and w1.status = 'canceled' and cancellation_details_reason not in ('payment_failed') and w1.prev_status = 'active' and (prev_cancelled_at is null) then 1
when w1.status = 'past_due' and w1.prev_status <> 'past_due' then 1
when canceled_at is not null and w1.status = 'canceled' and cancellation_details_reason in ('payment_failed') and w1.prev_status = 'active' and (prev_cancelled_at is null) then 1
when canceled_at is not null and w1.status = 'past_due' and (prev_cancelled_at is null) then 1
else 0 end
as is_cancel_or_failed,

--retention of cancel or payment failed
case
when canceled_at is null and prev_cancelled_at is not null then 1
when w1.status = 'active' and prev_status = 'past_due' then 1
else 0 end
as all_recovered,

frequency as frequency_computed,
case when a_a.last_sale_at is null then "no" else "yes" end as seller_tag,
a_a.country as sgt_country,
a_a.language,

from w1
left join `singulart-data.connected_sheets.all_artists` a_a on a_a.artist_id = w1.artist_id
--where data_batch_date >= '2025-01-01'
order by w1.id asc, rn asc),

before_final as (
select 
processing.*,
coalesce(hubspot_data.care_agent,"-") as care_agent,
hubspot_data.deal_email as hubspot_contact_email,
hubspot_data.dealid AS deal_id,
row_number() over (partition by processing.id, data_batch_date order by data_batch_date desc, hubspot_data.create_date asc) as final_dedup
from processing
left join hubspot_data on hubspot_data.artist_id = processing.artist_id 
  and (
    date(canceled_at) between date(date_sub(hubspot_data.create_date, interval 1 day)) and date(hubspot_data.create_date)
    or
    date(prev_cancelled_at) between date(date_sub(hubspot_data.create_date, interval 1 day)) and date(hubspot_data.create_date)
    or
    date(payment_failed_at) between date(date_sub(hubspot_data.create_date, interval 1 day)) and date(hubspot_data.create_date)
    or
    date(prev_payment_failed_at) between date(date_sub(hubspot_data.create_date, interval 1 day)) and date(hubspot_data.create_date)
  )
),

final as (
SELECT
*
,case 
  when lead(care_agent) over(partition by email order by data_batch_date asc) = "-" then care_agent
  else lead(care_agent) over(partition by email order by data_batch_date asc) end
as next_agent
FROM before_final
WHERE final_dedup = 1

ORDER BY id ASC, rn ASC)

select
current_date as run_date,
final.*
,coalesce(
case 
  when email in ('seralari@ymail.com') and data_batch_timestamp between '2026-05-01' and '2026-06-30' then 'Pia Bienfait'  
  when email in ('ascensoralparaiso@gmail.com') and data_batch_timestamp between '2026-05-01' and '2026-06-30' then 'Kevin Bejarano'
  when ((cancellation_event + is_past_due) > 0 and care_agent <> next_agent) then next_agent else care_agent end,care_agent)

as agent_fixed
,mrr.last_mrr/100 as mrr 
from final
left join mrr on mrr.subscription_id = final.id
where artist_id is not null and
(cancellation_event = 1 or canceller_retained = 1 or is_past_due = 1 or recovered_from_past_due = 1 or is_cancel_or_failed = 1 or all_recovered = 1)
and email not in (
'norvegino@gmail.com','keeleychevrier@gmail.com','carolamoraleshs@gmail.com','j1891p@gmail.com','maria_tana_designs@marijaart.com','koiserra@mail.de','sitorabrejneva@gmail.com','carol.veciana@gmail.com','info@mikesasaki.com','ignacioperezcaballero@gmail.com','sandra.haase28@googlemail.com','bastian.fojbos@hotmail.com','giosart93@gmail.com','anstavlac@gmail.com','giandeleo@outlook.it','ralf@haberich.com','laurelle.artiste@orange.fr','genes_sen@yahoo.com','sergeyisaverdyan@gmail.com','mail@christofschmidt.com','ulrikehahn@gmail.com','rocioartis@gmail.com','xeniaaltman24@gmail.com','lkljkhjknhj@gmail.com','martyna.wojcik.art@gmail.com','simone.bonnett@thesocialmanagers.com','brandismedina@gmail.com','darchiashvili.mariami25@gmail.com','info.nacht.art@gmail.com','mail@mikelvangelderen.nl','dk.derkomai@gmail.com','iamokartist@outlook.com','messodie@chimel.fr','atelierjhelle@proton.me','florence.deltoso@gmail.com','tanya_negrei@gmx.de','info@elybscphotography.com','pier.benetollo@gmail.com','alexandrateixeiradias@gmail.com','maryschiele83@gmail.com','djaffe.jaffe@gmail.com','mariapia.statile@gmail.com','daniel.giacchi@wanadoo.fr','harri@perunka.fi','charansangeeta@gmail.com','angelika.art@web.de','lennart@spraybar.de','ucciferri.contemporaryart@gmail.com','grinaldi312@icloud.com','goldart.boutique@gmail.com','sleise-art@web.de','hashem.alsharref@icloud.com','e_torony@yahoo.com','kafrinedesig@gmail.com','info@beateblume.de','francisduval34@orange.fr','lori_latham@icloud.com','jaguin.nathalie@orange.fr','andreas.kramer@posteo.de','fotografie@cckreutzer.de','hello@fionasolley.com','amesauvage.artistepeintre@gmail.com','artebiagio@gmail.com','PGoldenAndrews@gmail.com','massimo@sansavini.it','uholderith@gmail.com','emilie.hidocq@gmail.com','alexistroude.d@gmail.com','kontakt@heike-kirsch.de','irinaloreiartwork@gmail.com','vialeti@yahoo.fr','b.hholz@gmail.com','abstract.art.fr@gmail.com','info@blandine-galtier.net','artist@mirekkuzniar.de','antoniomateosprieto@gmail.com','Clf4d@yahoo.com','bildhaueratelier-eckert@t-online.de','ankesuess@stephenwayda.com','jagemann.art@gmail.com','etienne.perrone@gmail.com','jaiodosanjos@gmail.com','sandra.alegre212@gmail.com','info@christianlange.be','mogamogamomonga@gmail.com','christina@colouroftheday.de','fleurde@mweb.co.za','atelier.kuehne@gmail.com','stefan.lissinna@gmail.com','alexandragaitelli@gmail.com','yayastudio@gmail.com','andrea@andreamoench.de','info@nikolaus-gruenwald.com','olajostart@gmail.com','yvan.hesbois@gmail.com','fredi@gerts.ch','jeanpierre.walter@sfr.fr','sylvielaine2017@gmail.com','sonjajulian@gmx.de','lionelchevalier4@hotmail.com','ceo@harmeetsingh.art','everszakelijk@gmail.com','aurelie.pellat@hotmail.fr','zuzanka.garlikova@gmail.com','akoloel@gmail.com','wrb1@gmx-topmail.de','fomy999@naver.com','atelier@sjniklas.de','schoen-scharf@t-online.de','alb.diana.andrada@gmail.com','dominique@dominique-art.com','clementine.daudier@gmail.com','ruthie.mckenzie91@gmail.com','ljiljana.lukic@bluewin.ch','marianne@nolart.fr','weronika@raczynska.net','arcobruinenberg@gmail.com','graff.ac@gmail.com','bid.art@cegetel.net','ghleonelli@gmail.com','liuyz@hotmail.de','helgal370@gmail.com')
order by data_batch_timestamp asc, artist_id asc