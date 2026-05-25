--This query aims at retrieving the latest positions of the artworks of the 5 artists in the AP list. 
--It is based on the view_item_list events, and only considers the events from March 2026
--The query also takes into account the pagination of the AP list, by extracting the page number from the page_referrer field. 
WITH views_by_position AS (
  SELECT
    event_date,
    ge.sg_session_id,
    case 
      when a_a.is_blue_chip_artist = 1 then 'famous'
      when a_a.is_grand_artist = 1 then 'famous'
      else 'not_famous' end as famous_tag,
    coalesce(CAST(REGEXP_EXTRACT(page_referrer, r'[?&]page=(\d+)') AS INT64),1) AS page_number,
    i.item_id,
    i.item_brand,
    i.item_list_index,
    SAFE_CAST(i.item_list_index as INT64)*coalesce(CAST(REGEXP_EXTRACT(page_referrer, r'[?&]page=(\d+)') AS INT64),1) as position,
    MIN(ge.event_timestamp) AS first_view_timestamp,
    COUNT(DISTINCT ge.new_eventId) AS nb_views,
    row_number() over(partition by item_id order by event_date desc) as rn_desc
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN `singulart-data.connected_sheets.all_artworks` aa  on aa.artwork_id = SAFE_CAST(i.item_id AS INT64)
  INNER JOIN `singulart-data.connected_sheets.all_artists` a_a  on a_a.artist_id = aa.artist_id
  WHERE event_date >= '2026-03-01'
    AND i.item_list_name IN ('ap')
    AND i.item_list_index IS NOT NULL
    AND ge.event_name = "view_item_list"
    AND a_a.artist_id in (3969,18921,59212,50224,7037)
  GROUP BY 1, 2, 3, 4, 5, 6, 7,8
)

select
item_id,
page_number,
CASE WHEN safe_cast(item_list_index as INT64) < 25 then safe_cast(safe_cast(item_list_index as INT64)+1 as INT64) else 26 end as artwork_position,
CASE WHEN safe_cast(item_list_index as INT64) < 25 then safe_cast(safe_cast(item_list_index as INT64)+1 as INT64) else 26 end + (page_number-1)*24 artwork_ranking,
from views_by_position
where rn_desc = 1

