with

-- ── Hubspot Block ─────────────────────────────────────────────────────────────

-- MRR lookup: last active MRR per subscription (> 100 EUR)
mrr as (
  select
    subscription_id,
    last_mrr
  from (
    select
      --artist_id,
      subscription_id,
      mrr_change_in_eur as last_mrr,
      row_number() over(partition by subscription_id order by event_timestamp desc) rn
    from `singulart-data.sfa_acquisition.artists_mrr_changes`
    where event_type in ('ACTIVE_START')
  )
  where rn = 1
    and last_mrr > 100
),

-- Hubspot owners lookup
owners as (
  select
    cast(id as INT64) as new_user_id,
    firstname, lastname, email
  from `singulart-data.hubspot_stitch.owners`
),

-- Hubspot deals enriched with contact, artist, and care agent
hubspot_data as (
  select
    timestamp(d.property_createdate.value) as create_tmstp,
    coalesce(
      timestamp(d.property_closedate.value),
      timestamp(lead(d.property_createdate.value)
        over(partition by REGEXP_EXTRACT(property_dealname.value, r'[\w\.-]+@[\w\.-]+\.\w+') order by timestamp(d.property_createdate.value) asc)),
      current_timestamp()
    ) as end_tmstp,
    date(d.property_createdate.value) as create_date,
    timestamp(d.property_createdate.value) as create_timestamp,
    coalesce(
      date(d.property_closedate.value),
      lead(date(d.property_createdate.value))
        over(partition by REGEXP_EXTRACT(property_dealname.value, r'[\w\.-]+@[\w\.-]+\.\w+') order by timestamp(d.property_createdate.value) asc),
      current_date()
    ) as end_date,
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
    coalesce(Singulart_Artist_ID, cast(c.property_singulart_artist_id as INT64)) as artist_id,
    c.id as vid,
    REGEXP_EXTRACT(property_dealname.value, r'([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})') as deal_email,
    c.property_email as main_email,
    c.property_hs_additional_emails as additionnal_emails,
    concat(owners.firstname, ' ', owners.lastname) as care_agent,
    row_number() over(
      partition by c.property_email, date(d.property_createdate.value)
      order by timestamp(d.property_createdate.value) desc
    ) as rn
  from `singulart-data.hubspot_stitch.deals` d
  left join unnest(d.associations.associatedvids) vid
  left join owners on owners.new_user_id = SAFE_CAST(d.property_hubspot_owner_id.value as INT64)
  left join `singulart-data.hubspot_stitch.contacts` c on cast(c.id as string) = cast(vid.value as string)
  left join `singulart-datasandbox.hugo.temp_husbpot_contact_artist_id` thca on thca.Record_ID = vid.value
  where property_pipeline.value in ('142987873')
  order by dealid asc, d.property_createdate.value asc
),

-- ── Stripe Block ──────────────────────────────────────────────────────────────

-- Stripe reference tables: prices, products, artist plans, customers
prices as (
  select
    id, product_id, batch_timestamp,
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
    stripe_subscription_id, artist_id, level, frequency, current_period_start,
    row_number() over(partition by stripe_subscription_id order by current_period_start desc) as rn
  from `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
),

customers as (
  select
    email, created, id,
    address_country as stripe_country,
    row_number() over(partition by email, id order by created desc) rn
  from `singulart-data.stripe.customers`
  group by 1, 2, 3, 4
),

-- ── Subscription base layer ───────────────────────────────────────────────────

-- Raw subscription snapshot joined to customers and artist plans
sq as (
  select
    sub.id, sub.customer_id, stripe_country, sub.status, sap.artist_id, customers.email,
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

-- ── Window function layers ────────────────────────────────────────────────────

-- INNER LAYER: compute all window functions here
w as (
  select
    id, customer_id, stripe_country, status, artist_id, email,
    created, ended_at, start_date, current_period_start, current_period_end,
    discount_start, discount_end, canceled_at, cancel_at, payment_failed_at,
    cancel_at_period_end, data_batch_timestamp, data_batch_date,
    cancellation_details_reason, level, frequency, rn,
    lag(canceled_at) over(partition by id order by rn) as prev_cancelled_at,
    lag(cancel_at) over(partition by id order by rn) as prev_cancel_at,
    case
      when rn = 1 then 'subscription_creation'
      else lag(status) over(partition by id order by rn)
    end as prev_status
  from sq
),

w1 as (
  select
    id, customer_id, stripe_country, status, artist_id, email,
    created, ended_at, start_date, current_period_start, current_period_end,
    discount_start, discount_end, canceled_at, cancel_at, payment_failed_at,
    cancel_at_period_end, data_batch_timestamp, data_batch_date,
    cancellation_details_reason, level, frequency, rn,
    lag(canceled_at) over(partition by id order by rn) as prev_cancelled_at,
    lag(cancel_at) over(partition by id order by rn) as prev_cancel_at,
    case
      when rn = 1 then 'subscription_creation'
      else lag(status) over(partition by id order by rn)
    end as prev_status
  from w
  where not (status = 'past_due' and prev_status = 'past_due')
     or (canceled_at is not null and prev_cancelled_at is null)
     or (cancel_at is not null and prev_cancel_at is null)
),

-- ── Event classification ──────────────────────────────────────────────────────

-- OUTER LAYER: safely reference prev_cancelled_at and prev_status
processing as (
  select
    w1.id, w1.customer_id, w1.stripe_country, w1.status, w1.artist_id, w1.email,
    w1.created, w1.ended_at, w1.start_date, w1.current_period_start, w1.current_period_end,
    w1.discount_start, w1.discount_end, w1.canceled_at, w1.cancel_at, w1.payment_failed_at,
    w1.cancel_at_period_end, w1.data_batch_timestamp, w1.data_batch_date,
    w1.level, w1.rn, w1.prev_cancelled_at, w1.prev_cancel_at, w1.prev_status,
    case
      when w1.prev_status = 'past_due' then
        max(case when w1.status = 'past_due' and w1.prev_status <> 'past_due' then w1.payment_failed_at end)
          over(partition by w1.id order by w1.rn rows between unbounded preceding and 1 preceding)
      else null
    end as prev_payment_failed_at,
    lag(w1.current_period_end) over(partition by w1.id order by w1.rn) as prev_period_end,

    -- event type: 'cancellation' or 'payment_failed'
    case
      when canceled_at is not null and w1.status = 'active' and w1.cancellation_details_reason not in ('payment_failed') and coalesce(prev_cancelled_at, prev_cancel_at) is null then 'cancellation'
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason not in ('payment_failed') and w1.prev_status = 'active' and coalesce(prev_cancelled_at, prev_cancel_at) is null then 'cancellation'
      when w1.status not in ('canceled') and w1.cancellation_details_reason in ('cancellation_requested') and coalesce(prev_cancelled_at, prev_cancel_at) is null then 'cancellation'
      when coalesce(canceled_at, cancel_at) is null and coalesce(prev_cancelled_at, prev_cancel_at) is not null then 'cancellation'
      when w1.status = 'past_due' and w1.prev_status <> 'past_due' then 'payment_failed'
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason in ('payment_failed') and w1.prev_status = 'active' and prev_cancelled_at is null then 'payment_failed'
      when canceled_at is not null and w1.status = 'past_due' and prev_cancelled_at is null then 'payment_failed'
      when w1.status = 'active' and w1.prev_status = 'past_due' then 'payment_failed'
      else null
    end as event_type,

    -- event_date: batch timestamp when the event was first detected (for retained/recovered rows: original event date)
    case
      when canceled_at is not null and w1.status = 'active' and w1.cancellation_details_reason not in ('payment_failed') and coalesce(prev_cancelled_at, prev_cancel_at) is null then timestamp(w1.canceled_at)
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason not in ('payment_failed') and w1.prev_status = 'active' and coalesce(prev_cancelled_at, prev_cancel_at) is null then timestamp(w1.canceled_at)
      when w1.status not in ('canceled') and w1.cancellation_details_reason in ('cancellation_requested') and coalesce(prev_cancelled_at, prev_cancel_at) is null then coalesce(timestamp(w1.canceled_at), w1.data_batch_timestamp)
      when coalesce(canceled_at, cancel_at) is null and coalesce(prev_cancelled_at, prev_cancel_at) is not null then coalesce(timestamp(prev_cancelled_at), lag(w1.data_batch_timestamp) over(partition by w1.id order by w1.rn))
      when w1.status = 'past_due' and w1.prev_status <> 'past_due' then timestamp(w1.payment_failed_at)
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason in ('payment_failed') and w1.prev_status = 'active' and prev_cancelled_at is null then timestamp(w1.payment_failed_at)
      when canceled_at is not null and w1.status = 'past_due' and prev_cancelled_at is null then timestamp(w1.payment_failed_at)
      when w1.status = 'active' and w1.prev_status = 'past_due' then
        timestamp(max(case when w1.status = 'past_due' and w1.prev_status <> 'past_due' then w1.payment_failed_at end)
          over(partition by w1.id order by w1.rn rows between unbounded preceding and 1 preceding))
      else null
    end as event_date,

    -- due_date: cancellation → cancel_at or current_period_end; payment_failed → payment_failed_at + 14 days
    case
      when canceled_at is not null and w1.status = 'active' and w1.cancellation_details_reason not in ('payment_failed') and coalesce(prev_cancelled_at, prev_cancel_at) is null then coalesce(w1.cancel_at, w1.current_period_end)
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason not in ('payment_failed') and w1.prev_status = 'active' and coalesce(prev_cancelled_at, prev_cancel_at) is null then coalesce(w1.cancel_at, w1.current_period_end)
      when w1.status not in ('canceled') and w1.cancellation_details_reason in ('cancellation_requested') and coalesce(prev_cancelled_at, prev_cancel_at) is null then coalesce(w1.cancel_at, w1.current_period_end)
      when coalesce(canceled_at, cancel_at) is null and coalesce(prev_cancelled_at, prev_cancel_at) is not null then coalesce(prev_cancel_at, lag(w1.current_period_end) over(partition by w1.id order by w1.rn))
      when w1.status = 'past_due' and w1.prev_status <> 'past_due' then date_add(w1.payment_failed_at, interval 14 day)
      when canceled_at is not null and w1.status = 'canceled' and w1.cancellation_details_reason in ('payment_failed') and w1.prev_status = 'active' and prev_cancelled_at is null then date_add(w1.payment_failed_at, interval 14 day)
      when canceled_at is not null and w1.status = 'past_due' and prev_cancelled_at is null then date_add(w1.payment_failed_at, interval 14 day)
      when w1.status = 'active' and w1.prev_status = 'past_due' then
        date_add(max(case when w1.status = 'past_due' and w1.prev_status <> 'past_due' then w1.payment_failed_at end)
          over(partition by w1.id order by w1.rn rows between unbounded preceding and 1 preceding), interval 14 day)
      else null
    end as due_date,

    -- resolved_date: batch timestamp when cancellation was retained or payment failure was recovered
    case
      when coalesce(canceled_at, cancel_at) is null and coalesce(prev_cancelled_at, prev_cancel_at) is not null then w1.data_batch_timestamp
      when w1.status = 'active' and w1.prev_status = 'past_due' then w1.data_batch_timestamp
      else null
    end as resolved_date,

    w1.frequency as frequency_computed,
    case when a_a.last_sale_at is null then "no" else "yes" end as seller_tag,
    a_a.country as sgt_country,
    a_a.language

  from w1
  left join `singulart-data.connected_sheets.all_artists` a_a on a_a.artist_id = w1.artist_id
  --where data_batch_date >= '2025-01-01'
  order by w1.id asc, rn asc
),

-- ── Hubspot join & dedup ──────────────────────────────────────────────────────

-- Join processing output to Hubspot deals; dedup per subscription snapshot
before_final as (
  select
    processing.id, processing.customer_id, processing.stripe_country, processing.status, processing.artist_id, processing.email,
    processing.created, processing.ended_at, processing.start_date,
    processing.current_period_start, processing.current_period_end,
    processing.discount_start, processing.discount_end,
    processing.canceled_at, processing.cancel_at, processing.payment_failed_at,
    processing.cancel_at_period_end, processing.data_batch_timestamp, processing.data_batch_date,
    processing.level, processing.rn,
    processing.prev_cancelled_at, processing.prev_cancel_at, processing.prev_status,
    processing.prev_payment_failed_at, processing.prev_period_end,
    processing.event_type, processing.event_date, processing.due_date, processing.resolved_date,
    processing.frequency_computed, processing.seller_tag, processing.sgt_country, processing.language,
    coalesce(hubspot_data.care_agent, "-") as care_agent,
    hubspot_data.deal_email as hubspot_contact_email,
    hubspot_data.dealid as deal_id,
    row_number() over(
      partition by processing.id, data_batch_timestamp
      order by data_batch_timestamp desc, hubspot_data.create_date asc
    ) as final_dedup
  from processing
  left join hubspot_data on hubspot_data.artist_id = processing.artist_id
    and (
      date(canceled_at) between date(date_sub(hubspot_data.create_date, interval 1 day)) and date(hubspot_data.create_date)
      or date(prev_cancelled_at) between date(date_sub(hubspot_data.create_date, interval 1 day)) and date(hubspot_data.create_date)
      or date(payment_failed_at) between date(date_sub(hubspot_data.create_date, interval 1 day)) and date(hubspot_data.create_date)
      or date(prev_payment_failed_at) between date(date_sub(hubspot_data.create_date, interval 1 day)) and date(hubspot_data.create_date)
    )
),

-- ── Final output ──────────────────────────────────────────────────────────────

-- Add next_agent window and next_resolution_date; filter to one row per snapshot
final as (
  select
    before_final.id, before_final.customer_id, before_final.stripe_country, before_final.status, before_final.artist_id, before_final.email,
    before_final.created, before_final.ended_at, before_final.start_date,
    before_final.current_period_start, before_final.current_period_end,
    before_final.discount_start, before_final.discount_end,
    before_final.canceled_at, before_final.cancel_at, before_final.payment_failed_at,
    before_final.cancel_at_period_end, before_final.data_batch_timestamp, before_final.data_batch_date,
    before_final.level, before_final.rn,
    before_final.prev_cancelled_at, before_final.prev_cancel_at, before_final.prev_status,
    before_final.prev_payment_failed_at, before_final.prev_period_end,
    before_final.event_type, before_final.event_date, before_final.due_date, before_final.resolved_date,
    before_final.frequency_computed, before_final.seller_tag, before_final.sgt_country, before_final.language,
    before_final.care_agent, before_final.hubspot_contact_email, before_final.deal_id, before_final.final_dedup,
    case
      when lead(care_agent) over(partition by email order by data_batch_date asc) = "-" then care_agent
      else lead(care_agent) over(partition by email order by data_batch_date asc)
    end as next_agent,
    max(resolved_date) over(partition by id, event_type order by rn rows between 1 following and unbounded following) as next_resolution_date
  from before_final
  where final_dedup = 1
  order by id asc, rn asc
)

-- ── Final SELECT ──────────────────────────────────────────────────────────────

select
  current_date as run_date,
  final.id, final.customer_id, final.stripe_country, final.status, final.artist_id, final.email,
  final.created, final.ended_at, final.start_date,
  final.current_period_start, final.current_period_end,
  final.discount_start, final.discount_end,
  final.canceled_at, final.cancel_at, final.payment_failed_at,
  final.cancel_at_period_end, final.data_batch_timestamp, final.data_batch_date,
  final.level, final.rn,
  final.prev_cancelled_at, final.prev_cancel_at, final.prev_status,
  final.prev_payment_failed_at, final.prev_period_end,
  final.event_type, final.event_date, final.due_date, final.resolved_date,
  final.frequency_computed, final.seller_tag, final.sgt_country, final.language,
  final.care_agent, final.hubspot_contact_email, final.deal_id, final.final_dedup,
  final.next_agent,
  any_value(coalesce(
    case
      when cdmc.deal_owner is not null then cdmc.deal_owner
      when email in ('seralari@ymail.com') and data_batch_timestamp between '2026-05-01' and '2026-06-30' then 'Pia Bienfait'
      when email in ('ascensoralparaiso@gmail.com') and data_batch_timestamp between '2026-05-01' and '2026-06-30' then 'Kevin Bejarano'
      when (resolved_date is null and care_agent <> next_agent) then next_agent else care_agent
    end,
    care_agent
  )) as agent_fixed,
  mrr.last_mrr / 100 as mrr
from final
left join mrr on mrr.subscription_id = final.id
left join `singulart-datasandbox.hugo.canceller_deal_manual_corrections` cdmc
  on cdmc.artist_id = final.artist_id
  and date(cancellation_due_date) = date(final.cancel_at)
where final.artist_id is not null
  and event_type is not null
  and (resolved_date is not null or next_resolution_date is null)
/*and email not in (
    'norvegino@gmail.com','keeleychevrier@gmail.com','carolamoraleshs@gmail.com','j1891p@gmail.com','maria_tana_designs@marijaart.com','koiserra@mail.de','sitorabrejneva@gmail.com','carol.veciana@gmail.com','info@mikesasaki.com','ignacioperezcaballero@gmail.com','sandra.haase28@googlemail.com','bastian.fojbos@hotmail.com','giosart93@gmail.com','anstavlac@gmail.com','giandeleo@outlook.it','ralf@haberich.com','laurelle.artiste@orange.fr','genes_sen@yahoo.com','sergeyisaverdyan@gmail.com','mail@christofschmidt.com','ulrikehahn@gmail.com','rocioartis@gmail.com','xeniaaltman24@gmail.com','lkljkhjknhj@gmail.com','martyna.wojcik.art@gmail.com','simone.bonnett@thesocialmanagers.com','brandismedina@gmail.com','darchiashvili.mariami25@gmail.com','info.nacht.art@gmail.com','mail@mikelvangelderen.nl','dk.derkomai@gmail.com','iamokartist@outlook.com','messodie@chimel.fr','atelierjhelle@proton.me','florence.deltoso@gmail.com','tanya_negrei@gmx.de','info@elybscphotography.com','pier.benetollo@gmail.com','alexandrateixeiradias@gmail.com','maryschiele83@gmail.com','djaffe.jaffe@gmail.com','mariapia.statile@gmail.com','daniel.giacchi@wanadoo.fr','harri@perunka.fi','charansangeeta@gmail.com','angelika.art@web.de','lennart@spraybar.de','ucciferri.contemporaryart@gmail.com','grinaldi312@icloud.com','goldart.boutique@gmail.com','sleise-art@web.de','hashem.alsharref@icloud.com','e_torony@yahoo.com','kafrinedesig@gmail.com','info@beateblume.de','francisduval34@orange.fr','lori_latham@icloud.com','jaguin.nathalie@orange.fr','andreas.kramer@posteo.de','fotografie@cckreutzer.de','hello@fionasolley.com','amesauvage.artistepeintre@gmail.com','artebiagio@gmail.com','PGoldenAndrews@gmail.com','massimo@sansavini.it','uholderith@gmail.com','emilie.hidocq@gmail.com','alexistroude.d@gmail.com','kontakt@heike-kirsch.de','irinaloreiartwork@gmail.com','vialeti@yahoo.fr','b.hholz@gmail.com','abstract.art.fr@gmail.com','info@blandine-galtier.net','artist@mirekkuzniar.de','antoniomateosprieto@gmail.com','Clf4d@yahoo.com','bildhaueratelier-eckert@t-online.de','ankesuess@stephenwayda.com','jagemann.art@gmail.com','etienne.perrone@gmail.com','jaiodosanjos@gmail.com','sandra.alegre212@gmail.com','info@christianlange.be','mogamogamomonga@gmail.com','christina@colouroftheday.de','fleurde@mweb.co.za','atelier.kuehne@gmail.com','stefan.lissinna@gmail.com','alexandragaitelli@gmail.com','yayastudio@gmail.com','andrea@andreamoench.de','info@nikolaus-gruenwald.com','olajostart@gmail.com','yvan.hesbois@gmail.com','fredi@gerts.ch','jeanpierre.walter@sfr.fr','sylvielaine2017@gmail.com','sonjajulian@gmx.de','lionelchevalier4@hotmail.com','ceo@harmeetsingh.art','everszakelijk@gmail.com','aurelie.pellat@hotmail.fr','zuzanka.garlikova@gmail.com','akoloel@gmail.com','wrb1@gmx-topmail.de','fomy999@naver.com','atelier@sjniklas.de','schoen-scharf@t-online.de','alb.diana.andrada@gmail.com','dominique@dominique-art.com','clementine.daudier@gmail.com','ruthie.mckenzie91@gmail.com','ljiljana.lukic@bluewin.ch','marianne@nolart.fr','weronika@raczynska.net','arcobruinenberg@gmail.com','graff.ac@gmail.com','bid.art@cegetel.net','ghleonelli@gmail.com','liuyz@hotmail.de','helgal370@gmail.com','alaadoga@gmail.com')*/
group by all
order by data_batch_timestamp asc, artist_id asc
