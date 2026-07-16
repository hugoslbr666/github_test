with sales as (
select
a_s.artist_id as artist_id,
artwork_id,
country_shipment_from,
visitor_country,
visitor_id
from `singulart-data.connected_sheets.all_sales` a_s
inner join `singulart-data.connected_sheets.all_artists` a_a on a_a.artist_id = a_s.artist_id
where artwork_id is not null
and paid_at >= date_sub(current_date, interval 3 year)
),

impressions as (
select
safe_cast(i.item_brand as INT64) as artist_id,
safe_cast(i.item_id as INT64) as artwork_id,
va.first_country,
aa.artist_country_shipment_from,
count(*) as nb_impressions
from `singulart-data.ga_events.ga_events` ga, unnest(items) i
inner join `singulart-data.connected_sheets.all_artworks` aa on aa.artwork_id = safe_cast(i.item_id as INT64)
inner join `singulart-data.views.visitor_attribution` va on va.visitor_id = ga.visitor_id
where event_name in ('view_item_list')
and event_date >= date_sub(current_date, interval 3 year)
group by all
),

add_to_cart as (
select
aa.artist_id as artist_id,
scl.artwork_id,
stu.country as visitor_country,
aa.artist_country_shipment_from,
count(distinct scl.cart_id) as nb_add_to_cart
from `singulart-db-to-bigquery.singulartdb.sgt_carts_lines` scl
inner join `singulart-db-to-bigquery.singulartdb.sgt_carts` sc on sc.id = scl.cart_id
inner join `singulart-db-to-bigquery.singulartdb.sgt_tracking_users` stu on stu.customer_id = sc.customer_id
inner join `singulart-data.connected_sheets.all_artworks` aa on aa.artwork_id = scl.artwork_id
where scl.created_at >= date_sub(current_date, interval 3 year)
group by all
),

impressions_agg as (
select
artist_id,
sum(case when artist_country_shipment_from is null or first_country is null then 0 when artist_country_shipment_from = first_country then nb_impressions else 0 end) as local_impressions,
sum(case when artist_country_shipment_from is null or first_country is null then 0 when artist_country_shipment_from <> first_country then nb_impressions else 0 end) as international_impressions,
sum(case when artist_country_shipment_from is null or first_country is null then nb_impressions else 0 end) as unknown_impressions
from impressions
group by artist_id
),

sales_agg as (
select
artist_id,
count(case when country_shipment_from is not null and visitor_country is not null and country_shipment_from = visitor_country then artwork_id end) as local_sales,
count(case when country_shipment_from is not null and visitor_country is not null and country_shipment_from <> visitor_country then artwork_id end) as international_sales,
count(case when country_shipment_from is null or visitor_country is null then artwork_id end) as unknown_sales
from sales
group by artist_id
),

add_to_cart_agg as (
select
artist_id,
sum(case when artist_country_shipment_from is null or visitor_country is null then 0 when artist_country_shipment_from = visitor_country then nb_add_to_cart else 0 end) as local_add_to_cart,
sum(case when artist_country_shipment_from is null or visitor_country is null then 0 when artist_country_shipment_from <> visitor_country then nb_add_to_cart else 0 end) as international_add_to_cart,
sum(case when artist_country_shipment_from is null or visitor_country is null then nb_add_to_cart else 0 end) as unknown_add_to_cart
from add_to_cart
group by artist_id
)

select
coalesce(i.artist_id, s.artist_id, c.artist_id) as artist_id,
coalesce(i.local_impressions, 0) as local_impressions,
coalesce(i.international_impressions, 0) as international_impressions,
coalesce(i.unknown_impressions, 0) as unknown_impressions,
coalesce(c.local_add_to_cart, 0) as local_add_to_cart,
coalesce(c.international_add_to_cart, 0) as international_add_to_cart,
coalesce(c.unknown_add_to_cart, 0) as unknown_add_to_cart,
coalesce(s.local_sales, 0) as local_sales,
coalesce(s.international_sales, 0) as international_sales,
coalesce(s.unknown_sales, 0) as unknown_sales
from impressions_agg i
full outer join sales_agg s on s.artist_id = i.artist_id
full outer join add_to_cart_agg c on c.artist_id = coalesce(i.artist_id, s.artist_id)
where coalesce(i.artist_id, s.artist_id, c.artist_id) in (
--put artist ids below
63,225,259,272,395,434,536,585,613,662,707,1188,1202,1247,1298,1377,1387,1405,1407,1417,1424,1440,1453,1455,1464,1469,1514,1517,1546,1579,1589,1622,1682,1693,1697,1699,1717,1871,1947,1957,2021,2043,2049,2149,2167,2217,2247,2257,2281,2315,2429,2461,2479,2493,2533,2539,2623,2627,2651,2653,2657,2677,2723,2727,2747,2759,2815,2831,2903,2929,3011,3043,3115,3135,3141,3143,3209,3233,3275,3425,3485,3499,3631,3647,3675,3739,3741,3759,3797,3839,3845,3851,3857,3901,4137,4195,4415,4459,4469,4509,4557,4651,4657,4689,4691,4705,4717,4777,4853,4879,4893,4911,5013,5097,5177,5195,5377,5523,5699,5715,5723,5787,5801,6005,6015,6047,6057,6127,6159,6167,6173,6223,6371,6373,6455,6463,6587,6717,6739,6799,6893,6909,7037,7045,7117,7191,7275,7351,7421,7449,7559,7561,7945,7963,8107,8155,8167,8173,8217,8219,8243,8331,8337,8351,8363,8559,8575,8771,8815,8857,8883,8903,8937,8961,8963,8979,8997,9007,9023,9111,9169,9361,9505,9577,9683,9685,9787,9851,10023,10093,10109,10233,10269,10299,10347,10383,10399,10421,10471,10553,10619,10631,10821,10897,10929,10931,11023,11177,11317,11347,11377,11441,11457,11579,11619,11651,11733,11737,11995,12539,12551,12627,12665,12673,12783,12789,13007,13379,13407,13517,13849,13985,14007,14033,14039,14067,14077,14089,14105,14181,14313,14423,14729,14821,14901,14903,15033,15071,15197,15383,15597,15621,15627,15693,15847,15951,15999,16003,16019,16089,16175,16425,16503,16731,16983,17261,17493,17621,17813,18173,18293,18381,18529,18921,19099,19135,19381,19437,19467,19471,19475,19529,19775,19879,19881,19931,20055,20339,20377,20383,20543,20603,20689,21043,21105,21283,21375,21431,21433,21491,21553,21591,21631,21739,21757,21851,21973,22351,22691,22865,23097,23165,23515,23651,23883,24261,24299,24703,24951,25223,25373,25663,26353,26411,26415,26437,26567,26719,26851,26905,26967,26977,27303,27359,27363,27459,27607,27827,27925,28207,28309,28579,28659,28829,28903,28969,29037,29189,29279,30165,30355,30367,30417,30557,30783,31009,31033,31075,31277,31393,31581,31763,31839,31895,31911,32141,32143,32357,32365,32775,32943,32957,32989,33201,33343,33398,33426,33441,33478,33516,33520,33537,33602,33757,33818,33878,33910,33920,33969,34002,34325,34417,36192,36194,36212,36230,36394,36399,36414,36415,36427,36429,36442,36454,36461,36463,36475,36805,36870,36889,36924,36965,36973,37016,37060,37101,37189,37320,37382,37424,37427,37487,49788,49805,49984,50030,50074,50076,50087,50088,50091,50138,50153,52345,52479,52488,52576,53023,53069,53076,53114,53135,53257,53292,54688,56765,56854,56880,56986,57332,57358,58570,58849,58860,58886,58977,59194,59256,59267,59302,60016,60103,60170,60175,60182,60200,60263,60277,60288,60295,60304,60338,60352,60372,60403,60445,60494,60517,60530,60605,60687,60705,62137,62167,62415,62448,62456,62543,62944,62977,65105,65333,65342,65590,65601,65667,66351,66391,66546,66601,66663,66715,66717,66731,66808,66810,66880,67054,67139,67150,67244,67265,67306,67489,67739,67838,67855,67916,68019,68106,68177,68263,68352,68496,68853,68878,68969,69067,69210,69521,69588,69591,69654,69804,69836,69880,69939,69967,70088,70188,70296,70324,70354,70429,70461,70491,70514,70623,70641,70697,70702,70711,70722,70724,70808,70815,70831,70880,70889,70898,70984,70995,71037,71049,71064,71108,71122,71198,71205,71305,71306,71326,71340,71341,71371,71383,71394,76441,76507,76566,76574,76747,76768,76805,76813,76867,76895,77034,77040,77055,77084,77122,77125,77169,77213,77218,77221,77330,77355,77431,77449,77451,77507,77515,77559,77664,77679,77776,77820,77852,77895,77910,77921,77934,77944,77998,78303,78325,78399,78406,78600,78612,78920,79199,79341,79435,79581,79659,79712,79779,79794,79862,79873,79888,79960,79983,80021,80036,80078,80271,80320,80353,80438,80505,80558,80602,80663,80718,80778,80810,80856,80875,80884,80967,81141,81188,81274,81277,81285,81317,81321,81384,81472,81491,81522,81550,81590,81624,81648,81655,81664,81693,81696,81726,81785,81807,81817,81869,81886,81966,82030,82073,82272,82278,82434,82444,82458,82544,83125,83151,83414,83549,83778,83869
)