-- Row-level listing of the "local first sale" transactions used by
-- free_shipping_local_first_sale.sql's sales_agg (artist's first sale,
-- delivery_country = artist's country_shipment_from), tagged the same way:
-- pre/post the 2024-09-23 free-shipping policy, country, and promotion status.

with first_sale_local_filter as (
select
artwork_id,
artist_id,
country_shipment_from
from `singulart-data.connected_sheets.all_artworks` a_a
inner join `singulart-data.connected_sheets.all_artists` using(artist_id)
),

promo AS (
select
Date as promo_date,
is_promotion,
promotion_name
from `singulart-datasandbox.hugo.temp_promotions_calendar`
),

all_sales AS (
SELECT
a_s.sale_id,
DATE(paid_at) AS paid_at,
fslf.country_shipment_from,
amount_eur_paid
FROM `singulart-data.connected_sheets.all_sales` a_s
inner join first_sale_local_filter fslf on fslf.artwork_id = a_s.artwork_id and fslf.country_shipment_from = a_s.delivery_country
WHERE paid_at >= '2023-05-03' and paid_at < '2026-07-01'
and artist_order_number = 1
)

select
case when s.paid_at < '2024-09-23' then 'pre_free_shipping_fees_for_local_sales'
else 'post_free_shipping_fees_for_local_sales'
end as tag,
s.country_shipment_from as country_tag,
case when coalesce(p.is_promotion, 0) = 1 then 'on_promotion' else 'not_on_promotion' end as promo_tag,
paid_at,
s.sale_id,
s.amount_eur_paid
from all_sales s
left join promo p on p.promo_date = s.paid_at
order by 1 desc, 2, 3
