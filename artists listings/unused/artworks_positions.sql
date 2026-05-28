WITH views_by_position AS (
  SELECT
    event_date as event_date,
    coalesce(CAST(REGEXP_EXTRACT(page_referrer, r'[?&]page=(\d+)') AS INT64),1) AS page_number,
    i.item_id,
    i.item_brand,
    i.item_list_index,
    SAFE_CAST(i.item_list_index as INT64)*coalesce(CAST(REGEXP_EXTRACT(page_referrer, r'[?&]page=(\d+)') AS INT64),1) as position,
    MIN(ge.event_timestamp) AS first_view_timestamp,
    COUNT(DISTINCT ge.new_eventId) AS nb_views,
    row_number() over(partition by item_id order by date(event_date) desc) as rn_desc
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) i
  INNER JOIN `singulart-data.connected_sheets.all_artworks` aa  on aa.artwork_id = SAFE_CAST(i.item_id AS INT64)
  WHERE event_date >= '2026-04-01'
    AND i.item_list_name IN ('ap')
    AND NOT page_location like ('%?order=%') 
    AND i.item_list_index IS NOT NULL
    AND ge.event_name = "view_item_list"
    AND aa.artist_id in (3969,18921,59212,50224,7037)
  GROUP BY 1, 2, 3, 4, 5, 6
)

select
item_id,
cast(page_number as int64) as page_number,
cast(CASE WHEN safe_cast(item_list_index as INT64) < 25 then safe_cast(safe_cast(item_list_index as INT64)+1 as INT64) else 26 end as INT64) as artwork_position,
CASE WHEN safe_cast(item_list_index as INT64) < 25 then safe_cast(safe_cast(item_list_index as INT64)+1 as INT64) else 26 end + (page_number-1)*24 artwork_ranking,
from views_by_position
where rn_desc = 1