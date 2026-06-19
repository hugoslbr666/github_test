/*
  Per-artist aggregation of sessions that entered the site via their artist or artwork page.
  Source: internal tracking (sgt_tracking_visitors_sessions) — not GA.

  entry_sessions              – sessions whose first page (landing_tpl) was an artist or artwork page
  entry_sessions_organic_direct – subset where channel is organic search, direct, or social
                                  (paid channels SEM / SEA_BRAND / Display excluded)
  entry_BV                    – revenue (EUR) from sales made within those same sessions
                                (joined via all_sales.browsing_session_id = session_id)
*/

WITH entry_sessions AS (

    SELECT
        stvs.id                                     AS session_id,
        stvs.visitor_id,
        DATE(stvs.created_at)                       AS session_date,
        sr.landing_tpl,
        sr.landing_object_id,
        c.channel,
        c.channel_group
    FROM `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs
    INNER JOIN `singulart-data.views.session_referer` sr
        ON sr.session_id = stvs.id
    LEFT JOIN `singulart-data.views.campaigns` c
        ON c.campaign_id = stvs.tracking_campaign_id
    WHERE sr.landing_tpl LIKE '%artist%'
       --OR sr.landing_tpl LIKE '%artwork%'


),

-- Resolve to artist_id
-- artist landing:  landing_object_id = artist_id
-- artwork landing: landing_object_id = artwork_id → join all_artworks
entry_sessions_artist AS (

    SELECT
        es.session_id,
        es.visitor_id,
        es.session_date,
        es.channel,
        es.channel_group,
        CASE
            WHEN es.landing_tpl LIKE '%artist%'
                THEN SAFE_CAST(es.landing_object_id AS INT64)
            WHEN es.landing_tpl LIKE '%artwork%'
                THEN aw.artist_id
        END AS artist_id

    FROM entry_sessions es
    LEFT JOIN `singulart-data.connected_sheets.all_artworks` aw
        ON  aw.artwork_id = SAFE_CAST(es.landing_object_id AS INT64)
        AND es.landing_tpl LIKE '%artwork%'

    WHERE (es.landing_tpl LIKE '%artist%' AND SAFE_CAST(es.landing_object_id AS INT64) IS NOT NULL)
       OR (es.landing_tpl LIKE '%artwork%' AND aw.artist_id IS NOT NULL)

),

-- All sessions that touched an artist or artwork page (any pageview, not just landing)
sessions_touchpoint AS (

    SELECT
        pv.session_id,
        CASE
            WHEN pv.tpl LIKE '%artist%'
                THEN SAFE_CAST(pv.object_id AS INT64)
            WHEN pv.tpl LIKE '%artwork%'
                THEN aw.artist_id
        END AS artist_id
    FROM `singulart-data.views.all_pageviews` pv
    LEFT JOIN `singulart-data.connected_sheets.all_artworks` aw
        ON  aw.artwork_id = SAFE_CAST(pv.object_id AS INT64)
        AND pv.tpl LIKE '%artwork%'
    WHERE (pv.tpl LIKE '%artist%' AND SAFE_CAST(pv.object_id AS INT64) IS NOT NULL)
       OR (pv.tpl LIKE '%artwork%' AND aw.artist_id IS NOT NULL)

),

-- BV from sales attributed to the artist template (first-click attribution)
artist_attributed_bv AS (

    SELECT
        SAFE_CAST(sa.email_1st_click_landing_object_id AS INT64) AS artist_id,
        SUM(sa.purchaseEurAmountWithShipping)                    AS bv_attributed_to_artist
    FROM `singulart-data.connected_sheets.sales_attribution` sa
    WHERE /*sa.email_1st_click_campaign_name = 'TEMPLATE ARTIST'
      AND */sa.email_1st_click_landing_tpl   = 'artist'
    GROUP BY 1

),

-- Total BV from sales of the artist's own artworks, excluding sales already counted in entry_bv
-- (i.e. where the first click was on this artist's own template page)
artist_artwork_bv AS (

    SELECT
        aw.artist_id,
        SUM(s.amount_eur_paid) AS bv_artist_own_artworks
    FROM `singulart-data.connected_sheets.all_sales` s
    JOIN `singulart-data.connected_sheets.all_artworks` aw USING (artwork_id)
    LEFT JOIN `singulart-data.connected_sheets.sales_attribution` sa ON sa.sale_id = s.sale_id
    WHERE (
        sa.email_1st_click_landing_tpl IS NULL
        OR sa.email_1st_click_landing_tpl != 'artist'
        OR SAFE_CAST(sa.email_1st_click_landing_object_id AS INT64) != aw.artist_id
    )
    GROUP BY 1

)

SELECT
    sb.artist_id,
    aa.artist_name,
    COUNT(DISTINCT sb.session_id)                                   AS entry_sessions,
    COUNT(DISTINCT IF(
        sb.channel IN ('NON_BRAND_GOOGLE', 'BRAND_GOOGLE', 'DIRECT_ACCESS', 'FACEBOOK')
        OR sb.channel LIKE '%VIRAL%',
        sb.session_id,
        NULL
    ))                                                              AS entry_sessions_organic_direct,
    agr.total_results,
    agr.instagram_in_top5,
    agr.wikipedia_in_top5,
    agr.has_knowledge_panel,
    st.total_sessions_touchpoint_artist,
    aab.bv_attributed_to_artist entry_bv,
    aawb.bv_artist_own_artworks
FROM entry_sessions_artist sb
LEFT JOIN `singulart-data.connected_sheets.all_artists` aa USING (artist_id)
INNER JOIN `singulart-datasandbox.hugo.artist_google_results` agr ON agr.artist_id = sb.artist_id
LEFT JOIN artist_attributed_bv aab ON aab.artist_id = sb.artist_id
LEFT JOIN artist_artwork_bv aawb ON aawb.artist_id = sb.artist_id
LEFT JOIN (
    SELECT artist_id, COUNT(DISTINCT session_id) AS total_sessions_touchpoint_artist
    FROM sessions_touchpoint
    GROUP BY artist_id
) st ON st.artist_id = sb.artist_id
GROUP BY ALL
ORDER BY entry_sessions DESC