-- Campaign breakdown for a specific artist
-- Shows all metrics split by campaign for detailed analysis

DECLARE artist_id_param INT64 DEFAULT 36501; -- Change this to the artist_id you want to analyze

WITH artist_and_artwork_pageviews AS (
    -- Capture all pageviews from artist or artwork pages
    SELECT
        ap.session_id,
        ap.unique_pageview_id,
        CASE
            WHEN ap.tpl LIKE '%artist%'
                THEN SAFE_CAST(ap.object_id AS INT64)
            WHEN ap.tpl LIKE '%artwork%'
                THEN aw.artist_id
        END AS artist_id,
        CASE
            WHEN ap.tpl LIKE '%artist%' THEN 'artist'
            WHEN ap.tpl LIKE '%artwork%' THEN 'artwork'
        END AS page_type,
        c_first.campaign as entry_campaign,
        CASE
            WHEN c_first.campaign IN (
                "TEMPLATE_BLUECHIP_ARTIST",
                "TEMPLATE_GRAND_ARTIST",
                "TEMPLATE ARTIST",
                "TEMPLATE_LONGTAIL_ARTIST",
                "ADWORDS_ARTISTS",
                "GOOGLE_SHOPPING_GRAND_ARTISTS",
                "TEMPLATE ARTISTS",
                "EMAIL_TRANSACTIONAL_CUSTOM_FOLLOW_ARTISTS",
                "ADWORDS_FAMOUS_ARTISTS_COLLECTION",
                "PERFORMANCE_MAX_FAMOUS_ARTIST",
                "GOOGLE_SHOPPING_GRAND_ARTISTS_V_A",
                "ADWORDS_FAMOUS_ARTISTS",
                "SIGNATURE_ARTISTS",
                "ADWORDS_GRAND_ARTISTS",
                "ADWORDS_ARTIST_APPLICATION"
            ) THEN 'artist'
            WHEN c_first.campaign IN (
                "TEMPLATE ARTWORK",
                "TEMPLATE_ARTWORK_BLUECHIP",
                "TEMPLATE_ARTWORK_GRAND",
                "TEMPLATE_ARTWORK_AMATEUR",
                "TEMPLATE_ARTWORK_LONGTAIL",
                "TEMPLATE ARTWORKS"
            ) THEN 'artwork'
            ELSE NULL
        END AS campaign_type
    FROM `singulart-data.views.all_pageviews` ap
    INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs ON stvs.id = ap.session_id
    LEFT JOIN `singulart-data.connected_sheets.all_artworks` aw
        ON aw.artwork_id = SAFE_CAST(ap.object_id AS INT64)
        AND ap.tpl LIKE '%artwork%'
    LEFT JOIN `singulart-data.views.bot_visitor_ids` b ON b.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.visitor_attribution` va ON va.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.campaigns` c_first ON c_first.campaign_id = va.first_campaign_id
    WHERE (ap.tpl LIKE '%artist%' OR ap.tpl LIKE '%artwork%')
      AND b.visitor_id IS NULL
),

campaign_breakdown AS (
    SELECT
        entry_campaign,
        campaign_type,
        -- All sessions/pageviews from artist pages (any campaign)
        COUNT(DISTINCT CASE WHEN page_type = 'artist' THEN session_id END) as nb_sessions_artist_page,
        COUNT(DISTINCT CASE WHEN page_type = 'artist' THEN unique_pageview_id END) as nb_pageviews_artist_page,
        -- All sessions/pageviews from artwork pages (any campaign)
        COUNT(DISTINCT CASE WHEN page_type = 'artwork' THEN session_id END) as nb_sessions_artwork_page,
        COUNT(DISTINCT CASE WHEN page_type = 'artwork' THEN unique_pageview_id END) as nb_pageviews_artwork_page,
        -- Entry sessions/pageviews from artist campaigns
        COUNT(DISTINCT CASE WHEN campaign_type = 'artist' THEN session_id END) as nb_entry_sessions_artist_campaign,
        COUNT(DISTINCT CASE WHEN campaign_type = 'artist' THEN unique_pageview_id END) as nb_entry_pageviews_artist_campaign,
        -- Entry sessions/pageviews from artwork campaigns
        COUNT(DISTINCT CASE WHEN campaign_type = 'artwork' THEN session_id END) as nb_entry_sessions_artwork_campaign,
        COUNT(DISTINCT CASE WHEN campaign_type = 'artwork' THEN unique_pageview_id END) as nb_entry_pageviews_artwork_campaign
    FROM artist_and_artwork_pageviews
    WHERE artist_id = artist_id_param
    GROUP BY 1, 2
)

SELECT
    entry_campaign,
    campaign_type,
    nb_sessions_artist_page,
    nb_sessions_artwork_page,
    nb_sessions_artist_page + nb_sessions_artwork_page as nb_sessions_total,
    nb_pageviews_artist_page,
    nb_pageviews_artwork_page,
    nb_pageviews_artist_page + nb_pageviews_artwork_page as nb_pageviews_total,
    nb_entry_sessions_artist_campaign,
    nb_entry_sessions_artwork_campaign,
    nb_entry_sessions_artist_campaign + nb_entry_sessions_artwork_campaign as nb_entry_sessions_total,
    nb_entry_pageviews_artist_campaign,
    nb_entry_pageviews_artwork_campaign,
    nb_entry_pageviews_artist_campaign + nb_entry_pageviews_artwork_campaign as nb_entry_pageviews_total
FROM campaign_breakdown
ORDER BY nb_sessions_total DESC, entry_campaign