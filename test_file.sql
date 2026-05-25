select
a_s.artist_id
,a_s.artist
,a_s.artwork_id
,a_a.categories
,a_a.styles
,a_a.medium
,case when a_a.height_cm < a_a.width_cm then 'landscape' else 'portait' end as orientation
from `singulart-data.connected_sheets.all_sales` a_s
left join `singulart-data.connected_sheets.all_artworks` a_a on a_a.artwork_id = a_s.artwork_id 
where a_s.artist_id in (3969,18921,59212,50224,7037)
and a_s.artwork_id is not null
order by 1 asc