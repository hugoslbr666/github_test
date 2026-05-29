WITH views_on_artist_page AS (
  SELECT
    aa.artwork_id,
    COUNT(DISTINCT ge.new_eventId) AS nb_views
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN `singulart-data.connected_sheets.all_artworks` aa ON aa.artwork_id = SAFE_CAST(i.item_id AS INT64)
  WHERE event_date >= date_sub(current_date, INTERVAL 3 month)
    AND i.item_list_name IN ('ap')
    AND i.item_list_index IS NOT NULL
    AND ge.event_name = 'view_item_list'
  GROUP BY 1
),

similarity_computations AS (
  SELECT
    artists.artist_name,
    artists.artist_id,
    available_artwork_id,
    available.price_eur,
    available.picture,
    sum((1-similarity))                                                                                    AS sum_similarities,
    count(sold_artwork_id)                                                                                 AS nb_of_similarities,
    count(case when (1-similarity) >= 0.8                        then sold_artwork_id else null end)       AS nb_cluster_1,
    count(case when (1-similarity) < 0.8 and (1-similarity) >= 0.6 then sold_artwork_id else null end)    AS nb_cluster_2,
    count(case when (1-similarity) < 0.6 and (1-similarity) >= 0.4 then sold_artwork_id else null end)    AS nb_cluster_3,
    count(case when (1-similarity) < 0.4 and (1-similarity) >= 0.2 then sold_artwork_id else null end)    AS nb_cluster_4,
    count(case when (1-similarity) < 0.2                         then sold_artwork_id else null end)       AS nb_cluster_5
  FROM `singulart-datasandbox.hugo.temp_artworks_similarity_to_sold` temp
  LEFT JOIN `singulart-data.connected_sheets.all_artworks` available  ON available.artwork_id  = temp.available_artwork_id
  LEFT JOIN `singulart-data.connected_sheets.all_artworks` sold       ON sold.artwork_id       = temp.sold_artwork_id
  LEFT JOIN `singulart-data.connected_sheets.all_artists`  artists    ON artists.artist_id     = available.artist_id
  WHERE available_artwork_id <> sold_artwork_id
    AND available.artist_id = sold.artist_id
    AND artists.last_sale_at IS NOT NULL
  GROUP BY 1, 2, 3, 4, 5
)

SELECT
  sc.artist_name,
  sc.artist_id,
  sc.available_artwork_id,
  sc.price_eur,
  COALESCE(v.nb_views, 0)                                                                                  AS nb_views_L30days,
  sum_similarities
    * (nb_cluster_1 * 10.0 + nb_cluster_2 * 5.0 + nb_cluster_3 * 2.0 + nb_cluster_4 * 1.0 + nb_cluster_5 * 0.1)
    / nb_of_similarities                                                                                   AS global_similarity_score,
  sc.picture as last_artwork_picture
FROM similarity_computations sc
LEFT JOIN views_on_artist_page  v ON v.artwork_id = sc.available_artwork_id