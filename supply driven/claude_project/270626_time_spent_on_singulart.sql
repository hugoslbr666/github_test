SELECT
    aa.artist_id,
    aa.artist_name,
    aa.status,
    aa.email,
    date(aa.created_at) as account_created_at,
    aa.country,
    aa.country_shipment_from,
    aa.language,
    date(aa.last_sale_at) as last_sale_at,
    CASE
        WHEN aa.status IN ('LIVE_ONLINE', 'ONBOARDING') THEN DATE_DIFF(CURRENT_DATE(), DATE(aa.online_at), MONTH)
        WHEN aa.status IN ('LIVE_OFFLINE', 'NEVER_LOGGED_IN') THEN DATE_DIFF(DATE(aa.updated_at), DATE(aa.online_at), MONTH)
        ELSE NULL
    END as time_spent_on_singulart
FROM `singulart-data.connected_sheets.all_artists` aa
ORDER BY aa.artist_id

