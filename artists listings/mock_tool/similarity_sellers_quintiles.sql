WITH views_on_artist_page AS (
  SELECT
    aa.artist_id,
    aa.artwork_id,
    COUNT(DISTINCT ge.new_eventId) AS nb_views,
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN `singulart-data.connected_sheets.all_artworks` aa  ON aa.artwork_id = SAFE_CAST(i.item_id AS INT64)
  INNER JOIN `singulart-data.connected_sheets.all_artists` a_a  ON a_a.artist_id = aa.artist_id
  WHERE event_date >= date_sub(current_date, INTERVAL 3 month)
    AND i.item_list_name IN ('ap')
    AND i.item_list_index IS NOT NULL
    AND ge.event_name = 'view_item_list'
  GROUP BY 1, 2
),

similarity_computations AS (
  SELECT
    artists.artist_name,
    artists.artist_id,
    available_artwork_id,
    sum((1 - similarity))                                                                                  AS sum_similarities,
    count(sold_artwork_id)                                                                                 AS nb_of_similarities,
    count(CASE WHEN (1 - similarity) >= 0.8                        THEN sold_artwork_id ELSE NULL END)    AS nb_cluster_1,
    count(CASE WHEN (1 - similarity) < 0.8 AND (1 - similarity) >= 0.6 THEN sold_artwork_id ELSE NULL END) AS nb_cluster_2,
    count(CASE WHEN (1 - similarity) < 0.6 AND (1 - similarity) >= 0.4 THEN sold_artwork_id ELSE NULL END) AS nb_cluster_3,
    count(CASE WHEN (1 - similarity) < 0.4 AND (1 - similarity) >= 0.2 THEN sold_artwork_id ELSE NULL END) AS nb_cluster_4,
    count(CASE WHEN (1 - similarity) < 0.2                        THEN sold_artwork_id ELSE NULL END)    AS nb_cluster_5
  from `singulart-datasandbox.hugo.temp_artworks_similarity_to_sold` temp
  left join `singulart-data.connected_sheets.all_artworks` a_a on a_a.artwork_id = temp.available_artwork_id
  left join `singulart-data.connected_sheets.all_artworks` a_a2 on a_a2.artwork_id = temp.sold_artwork_id
  left join `singulart-data.connected_sheets.all_artists` artists on artists.artist_id = a_a.artist_id
  where available_artwork_id <> sold_artwork_id
    and a_a.artist_id = a_a2.artist_id
    and artists.last_sale_at is not null
  group by 1, 2, 3
),

scored AS (
  SELECT
    sc.artist_id,
    sc.artist_name,
    sc.available_artwork_id,
    sum_similarities
      * (nb_cluster_1 * 10.0 + nb_cluster_2 * 5.0 + nb_cluster_3 * 2.0 + nb_cluster_4 * 1.0 + nb_cluster_5 * 0.1)
      / nb_of_similarities                                          AS global_similarity_score,
    COALESCE(v.nb_views, 0)                                        AS nb_views_L30days,
    -- quintile assigned globally across all artworks (Q5 = most similar to sold artworks)
    NTILE(5) OVER (ORDER BY
      sum_similarities
        * (nb_cluster_1 * 10.0 + nb_cluster_2 * 5.0 + nb_cluster_3 * 2.0 + nb_cluster_4 * 1.0 + nb_cluster_5 * 0.1)
        / nb_of_similarities
    )                                                               AS similarity_quintile
  FROM similarity_computations sc
  LEFT JOIN views_on_artist_page v ON v.artwork_id = sc.available_artwork_id
)

SELECT
  artist_id,
  artist_name,

  -- number of artworks per quintile
  COUNTIF(similarity_quintile = 1)                                          AS nb_artworks_Q1,
  COUNTIF(similarity_quintile = 2)                                          AS nb_artworks_Q2,
  COUNTIF(similarity_quintile = 3)                                          AS nb_artworks_Q3,
  COUNTIF(similarity_quintile = 4)                                          AS nb_artworks_Q4,
  COUNTIF(similarity_quintile = 5)                                          AS nb_artworks_Q5,

  -- total views per quintile
  SUM(IF(similarity_quintile = 1, nb_views_L30days, 0))                     AS views_Q1,
  SUM(IF(similarity_quintile = 2, nb_views_L30days, 0))                     AS views_Q2,
  SUM(IF(similarity_quintile = 3, nb_views_L30days, 0))                     AS views_Q3,
  SUM(IF(similarity_quintile = 4, nb_views_L30days, 0))                     AS views_Q4,
  SUM(IF(similarity_quintile = 5, nb_views_L30days, 0))                     AS views_Q5,

  -- median views per quintile (APPROX_QUANTILES ignores NULLs)
  APPROX_QUANTILES(IF(similarity_quintile = 1, nb_views_L30days, NULL), 2)[OFFSET(1)] AS median_views_Q1,
  APPROX_QUANTILES(IF(similarity_quintile = 2, nb_views_L30days, NULL), 2)[OFFSET(1)] AS median_views_Q2,
  APPROX_QUANTILES(IF(similarity_quintile = 3, nb_views_L30days, NULL), 2)[OFFSET(1)] AS median_views_Q3,
  APPROX_QUANTILES(IF(similarity_quintile = 4, nb_views_L30days, NULL), 2)[OFFSET(1)] AS median_views_Q4,
  APPROX_QUANTILES(IF(similarity_quintile = 5, nb_views_L30days, NULL), 2)[OFFSET(1)] AS median_views_Q5

FROM scored
GROUP BY 1, 2
ORDER BY artist_name
