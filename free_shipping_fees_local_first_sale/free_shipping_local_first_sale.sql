with first_sale_local_filter as (
select
artwork_id,
artist_id,
country_shipment_from
from `singulart-data.connected_sheets.all_artworks` a_a
inner join `singulart-data.connected_sheets.all_artists` using(artist_id)
--where artist_order_number = 1 --and country_shipment_from = delivery_country
),

promo AS (
select
Date as promo_date,
is_promotion,
promotion_name
from `singulart-datasandbox.hugo.temp_promotions_calendar`
),

visitor_attribution AS (
select
visitor_id,
first_order_at
from `singulart-data.views.visitor_attribution`
),

-- one row per user: a user (sgt_tracking_users.id) can have several visitor_id rows in
-- sgt_tracking_visitors (multiple sessions/devices), so this collapses them to a single
-- first_order_at per user before joining into add_to_cart, avoiding a fan-out join.
user_first_order AS (
select
stv.user_id,
min(va.first_order_at) as first_order_at
from `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors` stv
left join visitor_attribution va on va.visitor_id = stv.id
group by 1
),

all_sales AS (
SELECT
a_s.artist_id,
DATE(paid_at) AS paid_at,
EXTRACT(YEAR FROM paid_at) AS year,
EXTRACT(MONTH FROM paid_at) AS month,
DATE_TRUNC(paid_at, MONTH) AS month_start,
a_s.artwork_id,
fslf.country_shipment_from,
a_s.customer_order_number,
amount_eur_paid
FROM `singulart-data.connected_sheets.all_sales` a_s
inner join first_sale_local_filter fslf on fslf.artwork_id = a_s.artwork_id and fslf.country_shipment_from = a_s.delivery_country
WHERE paid_at >= '2023-05-03' and paid_at < '2026-07-01'
and artist_order_number = 1
),

-- buyer_tag: 'non_buyer' if the visitor never has a first_order_at, 'new' if this event
-- happened before their first order (pre-purchase engagement), 'returning' if after.
views AS (
SELECT
DATE(ge.event_date) AS date,
aa.artist_id,
aa.country_shipment_from,
case
  when va.first_order_at is null then 'non_buyer'
  when ge.event_date < va.first_order_at then 'new'
  else 'returning'
end as buyer_tag,
COUNT(IF(ge.event_name = "view_item_list", ge.new_eventId, NULL)) AS nb_views,
COUNT(IF(ge.event_name = "select_item", ge.new_eventId, NULL)) AS nb_clicks
FROM `singulart-data.ga_events.ga_events` ge,
UNNEST(items) AS item
INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_countries` sc on sc.name = ge.country
INNER JOIN first_sale_local_filter aa ON safe_cast(aa.artwork_id as string)  = safe_cast(item.item_id as string)
left join all_sales a_s on a_s.artist_id = aa.artist_id
left join visitor_attribution va on va.visitor_id = ge.visitor_id
WHERE ge.event_date >= '2023-05-03'
and ge.event_date < '2026-07-01'
AND sc.iso2 = aa.country_shipment_from
and (event_date < a_s.paid_at or paid_at is null)
GROUP BY 1, 2, 3, 4
),

wishlist AS (
select
a_w.wishlist_created_at,
a_w.artwork_id,
fslf.country_shipment_from,
case
  when va.first_order_at is null then 'non_buyer'
  when a_w.wishlist_created_at < va.first_order_at then 'new'
  else 'returning'
end as buyer_tag
from `singulart-data.connected_sheets.all_wishlists` a_w
inner join `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors` stv on stv.id = a_w.visitor_id
inner join first_sale_local_filter fslf on fslf.artwork_id = a_w.artwork_id
left join all_sales a_s on a_s.artist_id = fslf.artist_id
left join visitor_attribution va on va.visitor_id = a_w.visitor_id
where a_w.wishlist_created_at >= '2023-05-03' and a_w.wishlist_created_at < '2026-07-01'
and (a_w.wishlist_created_at < a_s.paid_at or a_s.paid_at is null)
and stv.country = fslf.country_shipment_from
),

-- add_to_cart only carries a customer_id (via sgt_tracking_users), so we hop through
-- sgt_tracking_visitors.user_id to recover a visitor_id for the visitor_attribution join.
add_to_cart AS (
select
scl.created_at,
scl.artwork_id,
fslf.country_shipment_from,
case
  when ufo.first_order_at is null then 'non_buyer'
  when scl.created_at < ufo.first_order_at then 'new'
  else 'returning'
end as buyer_tag
from `singulart-db-to-bigquery.singulartdb.sgt_carts_lines` scl
inner join `singulart-db-to-bigquery.singulartdb.sgt_carts` sc on sc.id = scl.cart_id
inner join `singulart-db-to-bigquery.singulartdb.sgt_tracking_users` stu on stu.customer_id = sc.customer_id
inner join first_sale_local_filter fslf on fslf.artwork_id = scl.artwork_id
left join all_sales a_s on a_s.artist_id = fslf.artist_id
left join user_first_order ufo on ufo.user_id = stu.id
where scl.created_at >= '2023-05-03' and scl.created_at < '2026-07-01'
and (scl.created_at < a_s.paid_at or a_s.paid_at is null)
and stu.country = fslf.country_shipment_from
),

views_agg AS (
select
case when v.date < '2024-09-23' then 'pre_free_shipping_fees_for_local_sales'
else 'post_free_shipping_fees_for_local_sales'
end as tag,
v.country_shipment_from as country_tag,
case when coalesce(p.is_promotion, 0) = 1 then 'on_promotion' else 'not_on_promotion' end as promo_tag,
v.buyer_tag,
sum(v.nb_views) as nb_views,
sum(v.nb_clicks) as nb_clicks
from views v
left join promo p on p.promo_date = v.date
group by 1, 2, 3, 4
),

wl_agg AS (
select
case when w.wishlist_created_at < '2024-09-23' then 'pre_free_shipping_fees_for_local_sales'
else 'post_free_shipping_fees_for_local_sales'
end as tag,
w.country_shipment_from as country_tag,
case when coalesce(p.is_promotion, 0) = 1 then 'on_promotion' else 'not_on_promotion' end as promo_tag,
w.buyer_tag,
count(w.artwork_id) as nb_wl
from wishlist w
left join promo p on p.promo_date = DATE(w.wishlist_created_at)
group by 1, 2, 3, 4
),

cart_agg AS (
select
case when ca.created_at < '2024-09-23' then 'pre_free_shipping_fees_for_local_sales'
else 'post_free_shipping_fees_for_local_sales'
end as tag,
ca.country_shipment_from as country_tag,
case when coalesce(p.is_promotion, 0) = 1 then 'on_promotion' else 'not_on_promotion' end as promo_tag,
ca.buyer_tag,
count(ca.artwork_id) as nb_add_to_cart
from add_to_cart ca
left join promo p on p.promo_date = DATE(ca.created_at)
group by 1, 2, 3, 4
),

sales_agg AS (
select
case when s.paid_at < '2024-09-23' then 'pre_free_shipping_fees_for_local_sales'
else 'post_free_shipping_fees_for_local_sales'
end as tag,
s.country_shipment_from as country_tag,
case when coalesce(p.is_promotion, 0) = 1 then 'on_promotion' else 'not_on_promotion' end as promo_tag,
if(s.customer_order_number = 1, 'new', 'returning') as buyer_tag,
count(*) as nb_sales,
sum(s.amount_eur_paid) as amount_eur_paid,
count(distinct s.artist_id) as nb_unique_artists
from all_sales s
left join promo p on p.promo_date = s.paid_at
group by 1, 2, 3, 4
),

combos AS (
select tag, country_tag, promo_tag, buyer_tag from views_agg
union distinct
select tag, country_tag, promo_tag, buyer_tag from wl_agg
union distinct
select tag, country_tag, promo_tag, buyer_tag from cart_agg
union distinct
select tag, country_tag, promo_tag, buyer_tag from sales_agg
)

select
cm.tag,
cm.country_tag,
cm.promo_tag,
cm.buyer_tag,
v.nb_views,
v.nb_clicks,
w.nb_wl,
c.nb_add_to_cart,
s.nb_sales,
s.amount_eur_paid,
s.nb_unique_artists,
safe_divide(s.nb_sales, v.nb_views) as view_to_purchase_rate,
safe_divide(s.nb_sales, v.nb_clicks) as click_to_purchase_rate,
safe_divide(s.nb_sales, w.nb_wl) as wishlist_to_purchase_rate,
safe_divide(s.nb_sales, c.nb_add_to_cart) as cart_to_purchase_rate
from combos cm
left join views_agg v
  on v.tag = cm.tag and v.country_tag = cm.country_tag and v.promo_tag = cm.promo_tag and v.buyer_tag = cm.buyer_tag
left join wl_agg w
  on w.tag = cm.tag and w.country_tag = cm.country_tag and w.promo_tag = cm.promo_tag and w.buyer_tag = cm.buyer_tag
left join cart_agg c
  on c.tag = cm.tag and c.country_tag = cm.country_tag and c.promo_tag = cm.promo_tag and c.buyer_tag = cm.buyer_tag
left join sales_agg s
  on s.tag = cm.tag and s.country_tag = cm.country_tag and s.promo_tag = cm.promo_tag and s.buyer_tag = cm.buyer_tag
order by 1 desc, 2, 3, 4
