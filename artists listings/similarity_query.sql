select
  artist_name,
  artist_id,
  available_artwork_id,
  sum_similarities,
  nb_of_similarities,
  max_similarity,
  nb_cluster_1,
  nb_cluster_2,
  nb_cluster_3,
  nb_cluster_4,
  nb_cluster_5,
  -- global similarity score: sum(1-similarity) × weighted cluster factor
  -- higher = more similar to sold artworks
  sum_similarities
    * (nb_cluster_1 * 10.0 + nb_cluster_2 * 5.0 + nb_cluster_3 * 2.0 + nb_cluster_4 * 1.0 + nb_cluster_5 * 0.1)
    / nb_of_similarities as global_similarity_score
from (
  select
    artists.artist_name,
    artists.artist_id,
    available_artwork_id,
    sum((1-similarity))                                                                                    as sum_similarities,
    count(sold_artwork_id)                                                                             as nb_of_similarities,
    max((1-similarity))                                                                                    as max_similarity,
    count(case when (1-similarity) >= 0.8                       then sold_artwork_id else null end)         as nb_cluster_1,
    count(case when (1-similarity) < 0.8 and (1-similarity) >= 0.6 then sold_artwork_id else null end)         as nb_cluster_2,
    count(case when (1-similarity) < 0.6 and (1-similarity) >= 0.4 then sold_artwork_id else null end)         as nb_cluster_3,
    count(case when (1-similarity) < 0.4 and (1-similarity) >= 0.2 then sold_artwork_id else null end)         as nb_cluster_4,
    count(case when (1-similarity) < 0.2                      then sold_artwork_id else null end)         as nb_cluster_5
  from `singulart-datasandbox.hugo.temp_artworks_similarity_to_sold` temp
  left join `singulart-data.connected_sheets.all_artworks` a_a on a_a.artwork_id = temp.available_artwork_id
  left join `singulart-data.connected_sheets.all_artists` artists on artists.artist_id = a_a.artist_id
  where current_plan_level is not null
    and available_artwork_id <> sold_artwork_id
    and artists.last_sale_at is null
  group by 1, 2, 3
)