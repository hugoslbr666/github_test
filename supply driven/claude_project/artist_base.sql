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

-- BV from sales that were made in the same session (browsing_session_id = entry session)
session_bv AS (

    SELECT
        esa.session_id,
        esa.artist_id,
        esa.session_date,
        esa.channel,
        esa.channel_group,
        IFNULL(SUM(s.amount_eur_paid), 0) AS bv

    FROM entry_sessions_artist esa
    LEFT JOIN `singulart-data.connected_sheets.all_sales` s
        ON s.browsing_session_id = esa.session_id

    GROUP BY 1, 2, 3, 4, 5

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

    SUM(sb.bv)                                                      AS entry_BV
FROM session_bv sb
LEFT JOIN `singulart-data.connected_sheets.all_artists` aa USING (artist_id)
GROUP BY 1, 2
ORDER BY entry_sessions DESC