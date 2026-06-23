-- Artist pageviews CTE (matches 220626_session_artists.sql logic)
WITH artist_pageviews AS (
    SELECT
        ap.session_id,
        ap.unique_pageview_id,
        stvs.visitor_id,
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
        stvs.visitor_id,
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

-- Sales with attribution (from 220626_session_artists.sql)
artist_sales_with_attribution AS (
    SELECT
        s.artist_id as artist_sold_id,
        s.sale_id,
        s.amount_eur_paid,
        sa.browsing_session_id,
        stvs.visitor_id,
        s.paid_at as sale_date
    FROM `singulart-data.connected_sheets.all_sales` s
    LEFT JOIN `singulart-data.connected_sheets.sales_attribution` sa ON sa.sale_id = s.sale_id
    LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs ON stvs.id = sa.browsing_session_id
),

-- Categorize artist page sales
artist_sales_categorized AS (
    SELECT
        asa.artist_sold_id,
        asa.sale_id,
        asa.amount_eur_paid,
        MAX(CASE
            WHEN ap.artist_id = asa.artist_sold_id AND ap.campaign_type = 'artist' THEN 'same'
            WHEN ap.artist_id IS NOT NULL AND ap.campaign_type = 'artist' THEN 'other'
            ELSE 'none'
        END) as entry_type
    FROM artist_sales_with_attribution asa
    LEFT JOIN artist_pageviews ap
        ON ap.visitor_id = asa.visitor_id
        AND ap.session_id = asa.browsing_session_id
    GROUP BY asa.artist_sold_id, asa.sale_id, asa.amount_eur_paid
),

-- Artist BV breakdown
artist_bv_breakdown AS (
    SELECT
        artist_sold_id,
        SUM(amount_eur_paid) as total_bv,
        SUM(CASE WHEN entry_type = 'same' THEN amount_eur_paid ELSE 0 END) as entry_bv_same_artist,
        SUM(CASE WHEN entry_type = 'other' THEN amount_eur_paid ELSE 0 END) as entry_bv_other_artist,
        SUM(CASE WHEN entry_type = 'none' THEN amount_eur_paid ELSE 0 END) as other_bv
    FROM artist_sales_categorized
    GROUP BY 1
),

-- Categorize artwork page sales
artwork_sales_categorized AS (
    SELECT
        asa.artist_sold_id,
        asa.sale_id,
        asa.amount_eur_paid,
        MAX(CASE
            WHEN ap.artist_id = asa.artist_sold_id AND ap.campaign_type = 'artwork' THEN 'same'
            WHEN ap.artist_id IS NOT NULL AND ap.campaign_type = 'artwork' THEN 'other'
            ELSE 'none'
        END) as entry_type
    FROM artist_sales_with_attribution asa
    LEFT JOIN artwork_pageviews ap
        ON ap.visitor_id = asa.visitor_id
        AND ap.session_id = asa.browsing_session_id
    GROUP BY asa.artist_sold_id, asa.sale_id, asa.amount_eur_paid
),

-- Artwork BV breakdown
artwork_sales_with_attribution AS (
    SELECT
        artist_sold_id,
        SUM(amount_eur_paid) as total_bv,
        SUM(CASE WHEN entry_type = 'same' THEN amount_eur_paid ELSE 0 END) as entry_bv_same_artist,
        SUM(CASE WHEN entry_type = 'other' THEN amount_eur_paid ELSE 0 END) as entry_bv_other_artist,
        SUM(CASE WHEN entry_type = 'none' THEN amount_eur_paid ELSE 0 END) as other_bv
    FROM artwork_sales_categorized
    GROUP BY 1
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
    --COALESCE(apb.nb_pageviews_artist_page, 0) as nb_pageviews_artist_page,
    --COALESCE(apb.nb_pageviews_artwork_page, 0) as nb_pageviews_artwork_page,
    --COALESCE(apb.nb_pageviews_artist_page, 0) + COALESCE(apb.nb_pageviews_artwork_page, 0) as nb_pageviews_total,
    COALESCE(apb.nb_entry_sessions_artist_campaign, 0) as nb_entry_sessions_artist_campaign,
    COALESCE(apb.nb_entry_sessions_artwork_campaign, 0) as nb_entry_sessions_artwork_campaign,
    COALESCE(apb.nb_entry_sessions_artist_campaign, 0) + COALESCE(apb.nb_entry_sessions_artwork_campaign, 0) as nb_entry_sessions_total,
    --COALESCE(apb.nb_entry_pageviews_artist_campaign, 0) as nb_entry_pageviews_artist_campaign,
    --COALESCE(apb.nb_entry_pageviews_artwork_campaign, 0) as nb_entry_pageviews_artwork_campaign,
    --COALESCE(apb.nb_entry_pageviews_artist_campaign, 0) + COALESCE(apb.nb_entry_pageviews_artwork_campaign, 0) as nb_entry_pageviews_total,
    --COALESCE(abb.total_bv, 0) as artist_total_bv,
    COALESCE(abb.entry_bv_same_artist, 0) as artist_entry_bv_same_artist,
    COALESCE(abb.entry_bv_other_artist, 0) as artist_entry_bv_other_artist,
    --COALESCE(abb.other_bv, 0) as artist_entry_other_bv,
    --COALESCE(aswa.total_bv, 0) as artwork_total_bv,
    COALESCE(aswa.entry_bv_same_artist, 0) as artwork_entry_bv_same_artist,
    COALESCE(aswa.entry_bv_other_artist, 0) as artwork_entry_bv_other_artist,
    --COALESCE(aswa.other_bv, 0) as artwork_entry_other_bv
FROM `singulart-data.connected_sheets.all_artists` aa
LEFT JOIN artist_pageviews_breakdown apb ON apb.artist_id = aa.artist_id
LEFT JOIN artist_bv_breakdown abb ON abb.artist_sold_id = aa.artist_id
LEFT JOIN artwork_sales_with_attribution aswa ON aswa.artist_sold_id = aa.artist_id
ORDER BY artist_total_bv desc
