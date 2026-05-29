/*Global Query for computing CI on continuous variables*/
WITH non_intra AS (
  SELECT
    CASE
    WHEN ge.ss_exp LIKE "%211.0%" THEN 'Control'
    WHEN ge.ss_exp LIKE "%211.1%" THEN 'Test'
    ELSE '?' END AS version,
    COUNT(DISTINCT ge.ga_session_id) AS nb_ga_session_id,
    COUNT(DISTINCT IF(ge.session_engaged = 1, ge.ga_session_id, NULL)) AS nb_sessions_engaged,
    COUNT(DISTINCT IF(ge.event_name = "session_start", ge.new_eventId, NULL)) AS nb_sessions_start,

    -- # events (Corrigé avec UNNEST localisé)
    SUM(IF(ge.event_name = "view_item_list", (SELECT COUNT(DISTINCT CONCAT(IFNULL(i.item_id, 'null'), '-', IFNULL(i.item_list_index, 'null'))) FROM UNNEST(ge.items) i), 0)) AS nb_view_item,
    SUM(IF(ge.event_name = "view_item_list", (SELECT COUNT(DISTINCT CONCAT(IFNULL(i.item_id, 'null'), '-', IFNULL(i.item_list_index, 'null'))) FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), 0)) AS nb_view_item_catalog,
    COUNT(DISTINCT IF(ge.event_name = "select_item", ge.new_eventId, NULL)) AS nb_select_item,
    COUNT(DISTINCT IF(ge.event_name = "select_item" AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.new_eventId, NULL)) AS nb_select_item_catalog,
    COUNT(DISTINCT IF(ge.event_name = "artist_subscription", ge.new_eventId, NULL)) AS nb_follow_artist,
    COUNT(DISTINCT IF(ge.event_name = "add_to_wishlist", ge.new_eventId, NULL)) AS nb_add_to_wishlist,
    COUNT(DISTINCT IF(ge.event_name = "make_an_offer_submit", ge.new_eventId, NULL)) AS nb_mao,
    COUNT(DISTINCT IF(ge.event_name = "add_to_cart", ge.new_eventId, NULL)) AS nb_add_to_cart,
    COUNT(DISTINCT IF(ge.event_name = "purchase", ge.new_eventId, NULL)) AS nb_purchase,
    --COUNT(DISTINCT IF(ge.event_name = "newsletter_subscription", ge.new_eventId, NULL)) AS nb_newsletter_subscription,

    -- # sessions (Corrigé avec EXISTS pour les catalogues)
    COUNT(DISTINCT IF(ge.event_name = "view_item_list", ge.ga_session_id, NULL)) AS nb_sessions_view_item,
    COUNT(DISTINCT IF(ge.event_name = "view_item_list" AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.ga_session_id, NULL)) AS nb_sessions_view_item_catalog,
    COUNT(DISTINCT IF(ge.event_name = "select_item", ge.ga_session_id, NULL)) AS nb_sessions_select_item,
    COUNT(DISTINCT IF(ge.event_name = "select_item"  AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.ga_session_id, NULL)) AS nb_sessions_select_item_catalog,
    COUNT(DISTINCT IF(ge.event_name = "artist_subscription", ge.ga_session_id, NULL)) AS nb_sessions_follow_artist,
    COUNT(DISTINCT IF(ge.event_name = "add_to_wishlist", ge.ga_session_id, NULL)) AS nb_sessions_add_to_wishlist,
    COUNT(DISTINCT IF(ge.event_name = "make_an_offer_submit", ge.ga_session_id, NULL)) AS nb_sessions_mao,
    COUNT(DISTINCT IF(ge.event_name = "add_to_cart", ge.ga_session_id, NULL)) AS nb_sessions_add_to_cart,
    COUNT(DISTINCT IF(ge.event_name = "purchase", ge.ga_session_id, NULL)) AS nb_sessions_purchase,
    --COUNT(DISTINCT IF(ge.event_name = "newsletter_subscription", ge.ga_session_id, NULL)) AS nb_sessions_newsletter_subscription,
    
    -- Valeurs financières désormais protégées de la duplication
    SUM(IF(ge.event_name = "purchase", ge.event_value_in_usd*scr.rate, 0)) AS bv_eur_estimate,
    SUM(POWER(IF(ge.event_name = "purchase", ge.event_value_in_usd*scr.rate, 0), 2)) AS bv_squared_sum,
    COUNT(DISTINCT ge.visitor_id) AS nb_sg_visitor_id,
    COUNT(DISTINCT stv.user_id) AS nb_sg_user_id
  FROM `singulart-data.ga_events.ga_events` ge
  -- LEFT JOIN UNNEST(ge.items) AS items a été supprimé ici
  LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors` stv ON stv.id = ge.visitor_id
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies_rates` scr
      ON scr.base_id = 142 AND scr.target_id = 43
  WHERE ge.event_date >= "2026-02-25"
    AND ge.ga_session_id IS NOT NULL
    AND ge.ss_exp LIKE "%211%"
  GROUP BY 1
), intra AS (
  SELECT
    CASE
    WHEN ge.ss_exp LIKE "%211.0%" THEN 'Control'
    WHEN ge.ss_exp LIKE "%211.1%" THEN 'Test'
    ELSE '?' END AS version,
    COUNT(DISTINCT ge.ga_session_id) AS nb_ga_session_id,
    COUNT(DISTINCT IF(ge.session_engaged = 1, ge.ga_session_id, NULL)) AS nb_sessions_engaged,
    COUNT(DISTINCT IF(ge.event_name = "session_start", ge.new_eventId, NULL)) AS nb_sessions_start,

    -- # events (Corrigé avec UNNEST localisé)
    SUM(IF(ge.event_name = "view_item_list", (SELECT COUNT(DISTINCT CONCAT(IFNULL(i.item_id, 'null'), '-', IFNULL(i.item_list_index, 'null'))) FROM UNNEST(ge.items) i), 0)) AS nb_view_item,
    SUM(IF(ge.event_name = "view_item_list", (SELECT COUNT(DISTINCT CONCAT(IFNULL(i.item_id, 'null'), '-', IFNULL(i.item_list_index, 'null'))) FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), 0)) AS nb_view_item_catalog,
    COUNT(DISTINCT IF(ge.event_name = "select_item", ge.new_eventId, NULL)) AS nb_select_item,
    COUNT(DISTINCT IF(ge.event_name = "select_item" AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.new_eventId, NULL)) AS nb_select_item_catalog,
    COUNT(DISTINCT IF(ge.event_name = "artist_subscription", ge.new_eventId, NULL)) AS nb_follow_artist,
    COUNT(DISTINCT IF(ge.event_name = "add_to_wishlist", ge.new_eventId, NULL)) AS nb_add_to_wishlist,
    COUNT(DISTINCT IF(ge.event_name = "make_an_offer_submit", ge.new_eventId, NULL)) AS nb_mao,
    COUNT(DISTINCT IF(ge.event_name = "add_to_cart", ge.new_eventId, NULL)) AS nb_add_to_cart,
    COUNT(DISTINCT IF(ge.event_name = "purchase", ge.new_eventId, NULL)) AS nb_purchase,
    --COUNT(DISTINCT IF(ge.event_name = "newsletter_subscription", ge.new_eventId, NULL)) AS nb_newsletter_subscription,

    -- # sessions (Corrigé avec EXISTS pour les catalogues)
    COUNT(DISTINCT IF(ge.event_name = "view_item_list", ge.ga_session_id, NULL)) AS nb_sessions_view_item,
    COUNT(DISTINCT IF(ge.event_name = "view_item_list" AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.ga_session_id, NULL)) AS nb_sessions_view_item_catalog,
    COUNT(DISTINCT IF(ge.event_name = "select_item", ge.ga_session_id, NULL)) AS nb_sessions_select_item,
    COUNT(DISTINCT IF(ge.event_name = "select_item" AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.ga_session_id, NULL)) AS nb_sessions_select_item_catalog,
    COUNT(DISTINCT IF(ge.event_name = "artist_subscription", ge.ga_session_id, NULL)) AS nb_sessions_follow_artist,
    COUNT(DISTINCT IF(ge.event_name = "add_to_wishlist", ge.ga_session_id, NULL)) AS nb_sessions_add_to_wishlist,
    COUNT(DISTINCT IF(ge.event_name = "make_an_offer_submit", ge.ga_session_id, NULL)) AS nb_sessions_mao,
    COUNT(DISTINCT IF(ge.event_name = "add_to_cart", ge.ga_session_id, NULL)) AS nb_sessions_add_to_cart,
    COUNT(DISTINCT IF(ge.event_name = "purchase", ge.ga_session_id, NULL)) AS nb_sessions_purchase,
    --COUNT(DISTINCT IF(ge.event_name = "newsletter_subscription", ge.ga_session_id, NULL)) AS nb_sessions_newsletter_subscription,
    
    -- Valeurs financières désormais protégées de la duplication
    SUM(IF(ge.event_name = "purchase", ge.event_value_in_usd*scr.rate, 0)) AS bv_eur_estimate,
    SUM(POWER(IF(ge.event_name = "purchase", ge.event_value_in_usd*scr.rate, 0), 2)) AS bv_squared_sum,
    COUNT(DISTINCT ge.visitor_id) AS nb_sg_visitor_id,
    COUNT(DISTINCT stv.user_id) AS nb_sg_user_id
  FROM `singulart-data.ga_events.ga_events_intraday` ge
  -- LEFT JOIN UNNEST(ge.items) AS items a été supprimé ici
  LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors` stv ON stv.id = ge.visitor_id
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies_rates` scr
      ON scr.base_id = 142 AND scr.target_id = 43
  WHERE ge.event_date >= "2026-02-25"
    AND ge.ga_session_id IS NOT NULL
    AND ge.ss_exp LIKE "%211%"
  GROUP BY 1
), combined AS (
  SELECT * FROM non_intra
  UNION ALL
  SELECT * FROM intra
)
SELECT
  version,
  SUM(nb_ga_session_id) AS nb_ga_session_id,
  SUM(nb_sessions_engaged) AS nb_sessions_engaged,
  SUM(nb_sessions_start) AS nb_sessions_start,
  SUM(nb_view_item) AS nb_view_item,
  SUM(nb_view_item_catalog) AS nb_view_item_catalog,
  SUM(nb_select_item) AS nb_select_item,
  SUM(nb_select_item_catalog) AS nb_select_item_catalog,
  SUM(nb_follow_artist) AS nb_follow_artist,
  SUM(nb_add_to_wishlist) AS nb_add_to_wishlist,
  SUM(nb_mao) AS nb_mao,
  SUM(nb_add_to_cart) AS nb_add_to_cart,
  SUM(nb_purchase) AS nb_purchase,
  --SUM(nb_newsletter_subscription) AS nb_newsletter_subscription,
  SUM(nb_sessions_view_item) AS nb_sessions_view_item,
  SUM(nb_sessions_view_item_catalog) AS nb_sessions_view_item_catalog,
  SUM(nb_sessions_select_item) AS nb_sessions_select_item,
  SUM(nb_sessions_select_item_catalog) AS nb_sessions_select_item_catalog,
  SUM(nb_sessions_follow_artist) AS nb_sessions_follow_artist,
  SUM(nb_sessions_add_to_wishlist) AS nb_sessions_add_to_wishlist,
  SUM(nb_sessions_mao) AS nb_sessions_mao,
  SUM(nb_sessions_add_to_cart) AS nb_sessions_add_to_cart,
  SUM(nb_sessions_purchase) AS nb_sessions_purchase,
  --SUM(nb_sessions_newsletter_subscription) AS nb_sessions_newsletter_subscription,
  SUM(bv_eur_estimate) AS bv_eur_estimate,
  SUM(nb_sg_visitor_id) AS nb_sg_visitor_id,
  SUM(nb_sg_user_id) AS nb_sg_user_id,
  -- new stats
  SAFE_DIVIDE(SUM(bv_eur_estimate), SUM(nb_sg_visitor_id)) AS mean_bv_per_visitor,
  SAFE_DIVIDE(SUM(bv_squared_sum), SUM(nb_sg_visitor_id)) - POWER(SAFE_DIVIDE(SUM(bv_eur_estimate), SUM(nb_sg_visitor_id)), 2) AS variance_bv_per_visitor
FROM combined
GROUP BY version
ORDER BY version;