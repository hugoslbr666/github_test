WITH 
sales_per_artist AS (
  select
  artist_id,
  count(*) as nb_sales
  from `singulart-data.connected_sheets.all_sales`
  where artwork_id is not null
  group by 1
),

views_on_artist_page AS (
  SELECT
  aa.artist_id,
  aa.artwork_id,
    case when a_a.is_blue_chip_artist = 1 then 'famous'
          when a_a.is_grand_artist = 1 then 'famous'
      else 'not_famous' end as famous_tag,
    COUNT(DISTINCT ge.new_eventId) AS nb_views,
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN `singulart-data.connected_sheets.all_artworks` aa  on aa.artwork_id = SAFE_CAST(i.item_id AS INT64)
  INNER JOIN `singulart-data.connected_sheets.all_artists` a_a  on a_a.artist_id = aa.artist_id
  WHERE event_date >= '2026-05-01'
    AND i.item_list_name IN ('ap')
    --AND SAFE_CAST(i.item_list_index AS INT64) < 10
    AND i.item_list_index IS NOT NULL
    AND ge.event_name = "view_item_list"
  GROUP BY 1, 2, 3
),

similarity_computations as (
  select
    artists.artist_name,
    artists.artist_id,
    available_artwork_id,
    available.price_eur,
    available.picture,
    sum((1-similarity))                                                                                    as sum_similarities,
    count(sold_artwork_id)                                                                             as nb_of_similarities,
    max((1-similarity))                                                                                    as max_similarity,
    count(case when (1-similarity) >= 0.8                       then sold_artwork_id else null end)         as nb_cluster_1,
    count(case when (1-similarity) < 0.8 and (1-similarity) >= 0.6 then sold_artwork_id else null end)         as nb_cluster_2,
    count(case when (1-similarity) < 0.6 and (1-similarity) >= 0.4 then sold_artwork_id else null end)         as nb_cluster_3,
    count(case when (1-similarity) < 0.4 and (1-similarity) >= 0.2 then sold_artwork_id else null end)         as nb_cluster_4,
    count(case when (1-similarity) < 0.2                      then sold_artwork_id else null end)         as nb_cluster_5
  from `singulart-datasandbox.hugo.temp_artworks_similarity_to_sold` temp
  left join `singulart-data.connected_sheets.all_artworks` available on available.artwork_id = temp.available_artwork_id
  left join `singulart-data.connected_sheets.all_artists` artists on artists.artist_id = available.artist_id
  left join `singulart-data.connected_sheets.all_artworks` sold on sold.artwork_id = temp.sold_artwork_id
  left join sales_per_artist on sales_per_artist.artist_id = available.artist_id
  where current_plan_level is not null
    and available_artwork_id <> sold_artwork_id
    and available.medium = sold.medium
    and exists (
      select 1
      from unnest(split(available.categories, ',')) as avail_cat
      inner join unnest(split(sold.categories, ',')) as sold_cat on avail_cat = sold_cat
    )
    and (sales_per_artist.nb_sales < 3 or last_sale_at is null)
  group by 1, 2, 3, 4, 5
)

select
  sc.artist_name,
  sc.artist_id,
  sc.available_artwork_id,
  sc.price_eur,
  nb_views as nb_views_L30days,
  max_similarity,
  sum_similarities * 
  (nb_cluster_1 * 10.0 + nb_cluster_2 * 5.0 + nb_cluster_3 * 2.0 + nb_cluster_4 * 1.0 + nb_cluster_5 * 0.1) / nb_of_similarities 
  as global_similarity_score,
  sc.picture as last_artwork_picture
from similarity_computations sc
left join views_on_artist_page on views_on_artist_page.artwork_id = sc.available_artwork_id