-- Supply-driven metrics for the deactivated artist base.
-- Population:  artists whose first plan started before 2025-03-01 and who are no longer active.
-- Timeframe:   June 2024 – February 2025 (2024-06-01 to < 2025-03-01)

WITH all_artist_plans AS (
  SELECT
    *,
    FIRST_VALUE(level)      OVER (PARTITION BY artist_id ORDER BY started_at ASC, id ASC) AS first_plan_level,
    FIRST_VALUE(started_at) OVER (PARTITION BY artist_id ORDER BY started_at ASC, id ASC) AS first_plan_started_at,
    ROW_NUMBER()            OVER (PARTITION BY artist_id ORDER BY started_at DESC, id DESC) AS rn_last
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
),

artists_before_cutoff AS (
  SELECT DISTINCT artist_id, first_plan_level, first_plan_started_at
  FROM all_artist_plans
  WHERE first_plan_started_at < '2025-03-01'
),

last_plan AS (
  SELECT artist_id, level AS last_plan_level, ended_at AS last_plan_ended_at
  FROM all_artist_plans
  WHERE rn_last = 1
),

ever_had_paid_sub AS (
  SELECT DISTINCT artist_id
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  WHERE level != 'selected'
),

first_paid_sub AS (
  SELECT
    artist_id,
    MIN(started_at) AS first_paid_sub_started_at
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  WHERE level != 'selected'
  GROUP BY artist_id
),

deactivated_artists AS (
  SELECT
    abc.artist_id,
    abc.first_plan_level,
    abc.first_plan_started_at,
    lp.last_plan_level,
    lp.last_plan_ended_at,
    fps.first_paid_sub_started_at,
    CASE
      WHEN abc.first_plan_level = 'selected' AND eps.artist_id IS NULL
        THEN 'deactivated_selected_no_migration'
      WHEN abc.first_plan_level = 'selected' AND eps.artist_id IS NOT NULL
        THEN 'deactivated_selected_migrated_churned'
      ELSE
        'deactivated_new_artist_churned'
    END AS deactivated_type
  FROM artists_before_cutoff abc
  INNER JOIN last_plan lp
    ON abc.artist_id = lp.artist_id
  LEFT JOIN ever_had_paid_sub eps
    ON abc.artist_id = eps.artist_id
  LEFT JOIN first_paid_sub fps
    ON abc.artist_id = fps.artist_id
  WHERE lp.last_plan_ended_at IS NOT NULL
    AND lp.last_plan_ended_at < CURRENT_DATE()
),

-- Artist page views — filtered to deactivated artists and the analysis window
artist_pageviews AS (
  SELECT
    ap.session_id,
    ap.unique_pageview_id,
    stvs.visitor_id,
    SAFE_CAST(ap.object_id AS INT64) AS artist_id,
    'artist' AS page_type,
    c_first.campaign AS entry_campaign,
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
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs
    ON stvs.id = ap.session_id
  INNER JOIN deactivated_artists da
    ON SAFE_CAST(ap.object_id AS INT64) = da.artist_id
  LEFT JOIN `singulart-data.views.bot_visitor_ids` b
    ON b.visitor_id = stvs.visitor_id
  LEFT JOIN `singulart-data.views.visitor_attribution` va
    ON va.visitor_id = stvs.visitor_id
  LEFT JOIN `singulart-data.views.campaigns` c_first
    ON c_first.campaign_id = va.first_campaign_id
  WHERE ap.tpl = "artist"
    AND b.visitor_id IS NULL
    AND ap.created_at >= '2024-06-01'
    AND ap.created_at < '2025-03-01'
    AND (
      da.deactivated_type = 'deactivated_selected_no_migration'
      OR (da.deactivated_type = 'deactivated_new_artist_churned'
          AND ap.created_at >= da.last_plan_ended_at)
      OR (da.deactivated_type = 'deactivated_selected_migrated_churned'
          AND (ap.created_at < da.first_paid_sub_started_at
               OR ap.created_at >= da.last_plan_ended_at))
    )
),

-- Artwork page views — filtered to deactivated artists and the analysis window
artwork_pageviews AS (
  SELECT
    ap.session_id,
    ap.unique_pageview_id,
    stvs.visitor_id,
    aw.artist_id,
    'artwork' AS page_type,
    c_first.campaign AS entry_campaign,
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
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs
    ON stvs.id = ap.session_id
  INNER JOIN `singulart-data.connected_sheets.all_artworks` aw
    ON aw.artwork_id = SAFE_CAST(ap.object_id AS INT64)
  INNER JOIN deactivated_artists da
    ON aw.artist_id = da.artist_id
  LEFT JOIN `singulart-data.views.bot_visitor_ids` b
    ON b.visitor_id = stvs.visitor_id
  LEFT JOIN `singulart-data.views.visitor_attribution` va
    ON va.visitor_id = stvs.visitor_id
  LEFT JOIN `singulart-data.views.campaigns` c_first
    ON c_first.campaign_id = va.first_campaign_id
  WHERE ap.tpl LIKE '%artwork%'
    AND b.visitor_id IS NULL
    AND ap.created_at >= '2024-06-01'
    AND ap.created_at < '2025-03-01'
    AND (
      da.deactivated_type = 'deactivated_selected_no_migration'
      OR (da.deactivated_type = 'deactivated_new_artist_churned'
          AND ap.created_at >= da.last_plan_ended_at)
      OR (da.deactivated_type = 'deactivated_selected_migrated_churned'
          AND (ap.created_at < da.first_paid_sub_started_at
               OR ap.created_at >= da.last_plan_ended_at))
    )
),

all_pageviews AS (
  SELECT * FROM artist_pageviews
  UNION ALL
  SELECT * FROM artwork_pageviews
),

-- Sales filtered to deactivated artists and the analysis window
artist_sales_with_attribution AS (
  SELECT
    s.artist_id AS artist_sold_id,
    s.sale_id,
    s.amount_eur_paid,
    sa.browsing_session_id,
    stvs.visitor_id,
    s.paid_at AS sale_date
  FROM `singulart-data.connected_sheets.all_sales` s
  INNER JOIN deactivated_artists da
    ON s.artist_id = da.artist_id
  LEFT JOIN `singulart-data.connected_sheets.sales_attribution` sa
    ON sa.sale_id = s.sale_id
  LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs
    ON stvs.id = sa.browsing_session_id
  WHERE s.paid_at >= '2024-06-01'
    AND s.paid_at < '2025-03-01'
    AND (
      da.deactivated_type = 'deactivated_selected_no_migration'
      OR (da.deactivated_type = 'deactivated_new_artist_churned'
          AND s.paid_at >= da.last_plan_ended_at)
      OR (da.deactivated_type = 'deactivated_selected_migrated_churned'
          AND (s.paid_at < da.first_paid_sub_started_at
               OR s.paid_at >= da.last_plan_ended_at))
    )
),

artist_sales_categorized AS (
  SELECT
    asa.artist_sold_id,
    asa.sale_id,
    asa.amount_eur_paid,
    MAX(CASE
      WHEN ap.artist_id = asa.artist_sold_id AND ap.campaign_type = 'artist' THEN 'same'
      WHEN ap.artist_id IS NOT NULL AND ap.campaign_type = 'artist' THEN 'other'
      ELSE 'none'
    END) AS entry_type
  FROM artist_sales_with_attribution asa
  LEFT JOIN artist_pageviews ap
    ON ap.visitor_id = asa.visitor_id
    AND ap.session_id = asa.browsing_session_id
  GROUP BY asa.artist_sold_id, asa.sale_id, asa.amount_eur_paid
),

artist_bv_breakdown AS (
  SELECT
    artist_sold_id,
    SUM(amount_eur_paid)                                                      AS total_bv,
    SUM(CASE WHEN entry_type = 'same' THEN amount_eur_paid ELSE 0 END)        AS entry_bv_same_artist,
    SUM(CASE WHEN entry_type = 'other' THEN amount_eur_paid ELSE 0 END)       AS entry_bv_other_artist,
    SUM(CASE WHEN entry_type = 'none' THEN amount_eur_paid ELSE 0 END)        AS other_bv
  FROM artist_sales_categorized
  GROUP BY 1
),

artwork_sales_categorized AS (
  SELECT
    asa.artist_sold_id,
    asa.sale_id,
    asa.amount_eur_paid,
    MAX(CASE
      WHEN ap.artist_id = asa.artist_sold_id AND ap.campaign_type = 'artwork' THEN 'same'
      WHEN ap.artist_id IS NOT NULL AND ap.campaign_type = 'artwork' THEN 'other'
      ELSE 'none'
    END) AS entry_type
  FROM artist_sales_with_attribution asa
  LEFT JOIN artwork_pageviews ap
    ON ap.visitor_id = asa.visitor_id
    AND ap.session_id = asa.browsing_session_id
  GROUP BY asa.artist_sold_id, asa.sale_id, asa.amount_eur_paid
),

artwork_bv_breakdown AS (
  SELECT
    artist_sold_id,
    SUM(amount_eur_paid)                                                      AS total_bv,
    SUM(CASE WHEN entry_type = 'same' THEN amount_eur_paid ELSE 0 END)        AS entry_bv_same_artist,
    SUM(CASE WHEN entry_type = 'other' THEN amount_eur_paid ELSE 0 END)       AS entry_bv_other_artist,
    SUM(CASE WHEN entry_type = 'none' THEN amount_eur_paid ELSE 0 END)        AS other_bv
  FROM artwork_sales_categorized
  GROUP BY 1
),

artist_pageviews_breakdown AS (
  SELECT
    artist_id,
    COUNT(DISTINCT CASE WHEN page_type = 'artist'  THEN session_id END)        AS nb_sessions_artist_page,
    COUNT(DISTINCT CASE WHEN page_type = 'artist'  THEN unique_pageview_id END) AS nb_pageviews_artist_page,
    COUNT(DISTINCT CASE WHEN page_type = 'artwork' THEN session_id END)        AS nb_sessions_artwork_page,
    COUNT(DISTINCT CASE WHEN page_type = 'artwork' THEN unique_pageview_id END) AS nb_pageviews_artwork_page,
    COUNT(DISTINCT CASE WHEN campaign_type = 'artist'  THEN session_id END)    AS nb_entry_sessions_artist_campaign,
    COUNT(DISTINCT CASE WHEN campaign_type = 'artwork' THEN session_id END)    AS nb_entry_sessions_artwork_campaign
  FROM all_pageviews
  GROUP BY 1
)

SELECT
  da.artist_id,
  aa.artist_name,
  aa.status                                                                    AS current_status,
  da.deactivated_type,
  CASE
    WHEN aa.is_blue_chip_artist = 1 THEN 'Blue Chip Artist'
    WHEN aa.is_grand_artist = 1     THEN 'Grand Artist'
    ELSE 'Singulart Artist'
  END                                                                          AS artist_type,
  da.first_plan_started_at,
  da.last_plan_ended_at,
  DATE_DIFF(DATE(da.last_plan_ended_at), DATE(aa.online_at), DAY)             AS days_on_singulart,
  COALESCE(apb.nb_sessions_artist_page, 0)                                    AS nb_sessions_artist_page,
  COALESCE(apb.nb_sessions_artwork_page, 0)                                   AS nb_sessions_artwork_page,
  COALESCE(apb.nb_sessions_artist_page, 0) + COALESCE(apb.nb_sessions_artwork_page, 0)                               AS nb_sessions_total,
  COALESCE(apb.nb_entry_sessions_artist_campaign, 0)                          AS nb_entry_sessions_artist_campaign,
  COALESCE(apb.nb_entry_sessions_artwork_campaign, 0)                         AS nb_entry_sessions_artwork_campaign,
  COALESCE(apb.nb_entry_sessions_artist_campaign, 0)
    + COALESCE(apb.nb_entry_sessions_artwork_campaign, 0)                     AS nb_entry_sessions_total,
  COALESCE(abb.total_bv, 0)                                                   AS artist_total_bv,
  COALESCE(abb.entry_bv_same_artist, 0)                                       AS artist_entry_bv_same_artist,
  COALESCE(abb.entry_bv_other_artist, 0)                                      AS artist_entry_bv_other_artist,
  COALESCE(awb.entry_bv_same_artist, 0)                                       AS artwork_entry_bv_same_artist,
  COALESCE(awb.entry_bv_other_artist, 0)                                      AS artwork_entry_bv_other_artist,
FROM deactivated_artists da
LEFT JOIN `singulart-data.connected_sheets.all_artists` aa
  ON aa.artist_id = da.artist_id
LEFT JOIN artist_pageviews_breakdown apb
  ON apb.artist_id = da.artist_id
LEFT JOIN artist_bv_breakdown abb
  ON abb.artist_sold_id = da.artist_id
LEFT JOIN artwork_bv_breakdown awb
  ON awb.artist_sold_id = da.artist_id
ORDER BY artist_total_bv DESC
