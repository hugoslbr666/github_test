--the 
select 
artists.artist_name,
artists.artist_id,
available_artwork_id,
sum(similarity) as sum_similarities,
count(sold_artwork_id) as nb_of_similarities,
max(similarity) max_similarity,
count(case when similarity < 0.2 then sold_artwork_id else null end) as nb_cluster_1,
count(case when similarity >= 0.2 and similarity < 0.4 then sold_artwork_id else null end) as nb_cluster_2,
count(case when similarity >= 0.4 and similarity < 0.6 then sold_artwork_id else null end) as nb_cluster_3,
count(case when similarity >= 0.6 and similarity < 0.8 then sold_artwork_id else null end) as nb_cluster_4,
count(case when similarity >= 0.8 then sold_artwork_id else null end) as nb_cluster_5
from `singulart-datasandbox.hugo.temp_artworks_similarity_to_sold` temp
left join `singulart-data.connected_sheets.all_artworks` a_a on a_a.artwork_id = temp.available_artwork_id
left join `singulart-data.connected_sheets.all_artists` artists on artists.artist_id = a_a.artist_id 
where current_plan_level is not null and available_artwork_id <> sold_artwork_id
and artists.last_sale_at is null
group by 1,2,3