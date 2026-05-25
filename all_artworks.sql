select
a_a.artist_id
,a_a.artist
,a_a.artwork_id
,a_a.categories
,a_a.styles
,a_a.medium
,a_a.price_eur
,case when a_a.height_cm < a_a.width_cm then 'landscape' else 'portait' end as orientation
from `singulart-data.connected_sheets.all_artworks` a_a 
where a_a.artist_id in (3969,18921,59212,50224,7037)
and a_a.artwork_id is not null
and a_a.is_hiearchically_online = 1
order by 1 asc