WITH entry_sessions_artist_campaign AS (
    -- Sessions that viewed an artist page where first campaign is an artist campaign
    SELECT DISTINCT
        stvs.visitor_id,
        SAFE_CAST(ap.object_id AS INT64) as artist_viewed_id,
        ap.session_id
    FROM `singulart-data.views.all_pageviews` ap
    INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs ON stvs.id = ap.session_id
    LEFT JOIN `singulart-data.views.bot_visitor_ids` b ON b.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.visitor_attribution` va ON va.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.campaigns` c_first ON c_first.campaign_id = va.first_campaign_id
    WHERE ap.tpl = "artist"
      AND b.visitor_id IS NULL
      AND c_first.campaign IN (
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
        )
),

artist_sales_with_attribution AS (
    -- All sales of each artist's work with session and visitor info
    -- Uses artist_id directly from sales, covers artwork + commissions + options
    SELECT
        s.artist_id as artist_sold_id,
        s.sale_id,
        s.amount_eur_paid,
        sa.browsing_session_id,
        stvs.visitor_id,
        va.first_campaign_id,
        c_first.campaign as first_campaign
    FROM `singulart-data.connected_sheets.all_sales` s
    LEFT JOIN `singulart-data.connected_sheets.sales_attribution` sa ON sa.sale_id = s.sale_id
    LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs ON stvs.id = sa.browsing_session_id
    LEFT JOIN `singulart-data.views.visitor_attribution` va ON va.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.campaigns` c_first ON c_first.campaign_id = va.first_campaign_id
),

artist_sales_categorized AS (
    SELECT
        aswa.artist_sold_id,
        aswa.sale_id,
        aswa.amount_eur_paid,
        MAX(CASE
            WHEN esac.artist_viewed_id = aswa.artist_sold_id THEN 'same'
            WHEN esac.artist_viewed_id IS NOT NULL AND esac.artist_viewed_id != aswa.artist_sold_id THEN 'other'
            ELSE 'none'
        END) as entry_type
    FROM artist_sales_with_attribution aswa
    LEFT JOIN entry_sessions_artist_campaign esac
        ON esac.visitor_id = aswa.visitor_id
        AND esac.session_id = aswa.browsing_session_id
    GROUP BY aswa.artist_sold_id, aswa.sale_id, aswa.amount_eur_paid
),

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

artist_supply_driven_bv AS (
    -- BV generated on OTHER artists by visitors who entered via this artist's page
    SELECT
        esac.artist_viewed_id as artist_id,
        SUM(aswa.amount_eur_paid) as supply_driven_bv
    FROM artist_sales_with_attribution aswa
    INNER JOIN entry_sessions_artist_campaign esac
        ON esac.visitor_id = aswa.visitor_id
        AND esac.session_id = aswa.browsing_session_id
    WHERE aswa.artist_sold_id != esac.artist_viewed_id
    GROUP BY 1
),

artist_pageviews AS (
    SELECT
        SAFE_CAST(ap.object_id AS INT64) as artist_id,
        COUNT(DISTINCT ap.session_id) as nb_sessions,
        COUNT(DISTINCT ap.unique_pageview_id) as nb_pageviews,
        COUNT(DISTINCT CASE
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
            ) THEN ap.session_id
        END) as nb_sessions_first_click,
        COUNT(DISTINCT CASE
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
            ) THEN ap.unique_pageview_id
        END) as nb_pageviews_first_click
    FROM `singulart-data.views.all_pageviews` ap
    INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs ON stvs.id = ap.session_id
    LEFT JOIN `singulart-data.views.bot_visitor_ids` b ON b.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.visitor_attribution` va ON va.visitor_id = stvs.visitor_id
    LEFT JOIN `singulart-data.views.campaigns` c_first ON c_first.campaign_id = va.first_campaign_id
    WHERE ap.tpl = "artist"
      AND b.visitor_id IS NULL
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
    COALESCE(apv.nb_sessions, 0) as nb_sessions,
    COALESCE(apv.nb_pageviews, 0) as nb_pageviews,
    COALESCE(apv.nb_sessions_first_click, 0) as nb_sessions_first_click,
    COALESCE(apv.nb_pageviews_first_click, 0) as nb_pageviews_first_click,
    COALESCE(abd.total_bv, 0) as total_bv,
    COALESCE(abd.entry_bv_same_artist, 0) as entry_bv_same_artist,
    COALESCE(abd.entry_bv_other_artist, 0) as entry_bv_other_artist,
    COALESCE(abd.other_bv, 0) as other_bv,
    COALESCE(asdb.supply_driven_bv, 0) as supply_driven_bv
FROM `singulart-data.connected_sheets.all_artists` aa
LEFT JOIN artist_pageviews apv ON apv.artist_id = aa.artist_id
LEFT JOIN artist_bv_breakdown abd ON abd.artist_sold_id = aa.artist_id
LEFT JOIN artist_supply_driven_bv asdb ON asdb.artist_id = aa.artist_id
ORDER BY 1
