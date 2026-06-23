-- Extract individual supply-driven sales for a given artist_id
-- Matches the supply_driven_bv metric from 220626_session_artists.sql
-- Supply-driven sales: sales of OTHER artists made in sessions where visitor entered via this artist's page with an artist campaign

DECLARE artist_id_param INT64 DEFAULT 4477; -- Change this to the artist_id you want to analyze

WITH entry_sessions_artist_campaign AS (
    -- Sessions that viewed the specified artist's page where first campaign is an artist campaign
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
      AND SAFE_CAST(ap.object_id AS INT64) = artist_id_param
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
    -- All sales with session and visitor info
    SELECT
        s.artist_id as artist_sold_id,
        s.sale_id,
        s.amount_eur_paid,
        sa.browsing_session_id,
        stvs.visitor_id,
        s.paid_at as sale_date,
        aa.artist_name
    FROM `singulart-data.connected_sheets.all_sales` s
    LEFT JOIN `singulart-data.connected_sheets.sales_attribution` sa ON sa.sale_id = s.sale_id
    LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs ON stvs.id = sa.browsing_session_id
    LEFT JOIN `singulart-data.connected_sheets.all_artists` aa ON aa.artist_id = s.artist_id
)

SELECT
    aswa.sale_id,
    aswa.amount_eur_paid,
    aswa.artist_sold_id,
    aswa.artist_name as sold_artist_name,
    aswa.visitor_id,
    artist_id_param as entry_artist_id,
    esac.session_id,
    aswa.browsing_session_id,
    aswa.sale_date
FROM artist_sales_with_attribution aswa
INNER JOIN entry_sessions_artist_campaign esac
    ON esac.visitor_id = aswa.visitor_id
    AND esac.session_id = aswa.browsing_session_id
WHERE aswa.artist_sold_id != artist_id_param
ORDER BY aswa.sale_date DESC, aswa.amount_eur_paid DESC
