-- Artist pageviews CTE (matches 220626_session_artists.sql logic)
WITH artist_pageviews AS (
    SELECT
        ap.session_id,
        ap.unique_pageview_id,
        SAFE_CAST(ap.object_id AS INT64) as artist_id,
        'artist' as page_type,
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
            ELSE NULL
        END AS campaign_type
    FROM `singulart-data.views.all_pageviews` ap
    INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs ON stvs.id = ap.session_id
    LEFT JOIN `singulart-data.views.bot_visitor_ids` b ON b.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.visitor_attribution` va ON va.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.campaigns` c_first ON c_first.campaign_id = va.first_campaign_id
    WHERE ap.tpl = "artist"
      AND b.visitor_id IS NULL
),

-- Artwork pageviews CTE
artwork_pageviews AS (
    SELECT
        ap.session_id,
        ap.unique_pageview_id,
        aw.artist_id,
        'artwork' as page_type,
        c_first.campaign as entry_campaign,
        CASE
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
    INNER JOIN `singulart-data.connected_sheets.all_artworks` aw
        ON aw.artwork_id = SAFE_CAST(ap.object_id AS INT64)
    LEFT JOIN `singulart-data.views.bot_visitor_ids` b ON b.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.visitor_attribution` va ON va.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.campaigns` c_first ON c_first.campaign_id = va.first_campaign_id
    WHERE ap.tpl LIKE '%artwork%'
      AND b.visitor_id IS NULL
),

-- Combined pageviews
all_pageviews AS (
    SELECT * FROM artist_pageviews
    UNION ALL
    SELECT * FROM artwork_pageviews
),

artist_pageviews_breakdown AS (
    SELECT
        artist_id,
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
    FROM all_pageviews
    GROUP BY 1
)

SELECT
    aa.artist_id,
    aa.artist_name,
    CASE
        WHEN aa.is_blue_chip_artist = 1 THEN 'Blue Chip Artist'
        WHEN aa.is_grand_artist = 1 THEN 'Grand Artist'
        ELSE 'Singulart Artist'
    END as artist_type,
    COALESCE(apb.nb_sessions_artist_page, 0) as nb_sessions_artist_page,
    COALESCE(apb.nb_sessions_artwork_page, 0) as nb_sessions_artwork_page,
    COALESCE(apb.nb_sessions_artist_page, 0) + COALESCE(apb.nb_sessions_artwork_page, 0) as nb_sessions_total,
    COALESCE(apb.nb_pageviews_artist_page, 0) as nb_pageviews_artist_page,
    COALESCE(apb.nb_pageviews_artwork_page, 0) as nb_pageviews_artwork_page,
    COALESCE(apb.nb_pageviews_artist_page, 0) + COALESCE(apb.nb_pageviews_artwork_page, 0) as nb_pageviews_total,
    COALESCE(apb.nb_entry_sessions_artist_campaign, 0) as nb_entry_sessions_artist_campaign,
    COALESCE(apb.nb_entry_sessions_artwork_campaign, 0) as nb_entry_sessions_artwork_campaign,
    COALESCE(apb.nb_entry_sessions_artist_campaign, 0) + COALESCE(apb.nb_entry_sessions_artwork_campaign, 0) as nb_entry_sessions_total,
    COALESCE(apb.nb_entry_pageviews_artist_campaign, 0) as nb_entry_pageviews_artist_campaign,
    COALESCE(apb.nb_entry_pageviews_artwork_campaign, 0) as nb_entry_pageviews_artwork_campaign,
    COALESCE(apb.nb_entry_pageviews_artist_campaign, 0) + COALESCE(apb.nb_entry_pageviews_artwork_campaign, 0) as nb_entry_pageviews_total
FROM `singulart-data.connected_sheets.all_artists` aa
LEFT JOIN artist_pageviews_breakdown apb ON apb.artist_id = aa.artist_id
ORDER BY 1
