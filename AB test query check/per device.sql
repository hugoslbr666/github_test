WITH non_intra AS (
  SELECT
    ge.event_date,
    CASE
      WHEN ge.ss_exp LIKE "%211.0%" THEN "Control"
      WHEN ge.ss_exp LIKE "%211.1%" THEN "Test"
      ELSE "?"
    END as version,
    COUNT(DISTINCT ge.ga_session_id) as nb_ga_session_id,
    COUNT(DISTINCT IF(ge.session_engaged = 1,ge.ga_session_id,NULL)) as nb_sessions_engaged,
    COUNT(DISTINCT IF(ge.event_name = "session_start",ge.new_eventId,NULL)) as nb_sessions_start,

    -- # events (Corrigé avec UNNEST localisé)
    SUM(IF(ge.event_name = "view_item_list", (SELECT COUNT(DISTINCT CONCAT(IFNULL(i.item_id, 'null'), '-', IFNULL(i.item_list_index, 'null'))) FROM UNNEST(ge.items) i), 0)) AS nb_view_item,
    SUM(IF(ge.event_name = "view_item_list", (SELECT COUNT(DISTINCT CONCAT(IFNULL(i.item_id, 'null'), '-', IFNULL(i.item_list_index, 'null'))) FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), 0)) AS nb_view_item_catalog,
    COUNT(DISTINCT IF(ge.event_name = "select_item", ge.new_eventId, NULL)) AS nb_select_item,
    COUNT(DISTINCT IF(ge.event_name = "select_item" AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.new_eventId, NULL)) AS nb_select_item_catalog,

    --COUNT(DISTINCT IF(ge.event_name = "artist_subscription",ge.new_eventId,NULL)) as nb_follow_artist,
    COUNT(DISTINCT IF(ge.event_name = "add_to_wishlist",ge.new_eventId,NULL)) as nb_add_to_wishlist,
    COUNT(DISTINCT IF(ge.event_name = "make_an_offer_submit",ge.new_eventId,NULL)) as nb_mao,
    COUNT(DISTINCT IF(ge.event_name = "add_to_cart",ge.new_eventId,NULL)) as nb_add_to_cart,
    COUNT(DISTINCT IF(ge.event_name = "purchase",ge.new_eventId,NULL)) as nb_purchase,
    --COUNT(DISTINCT IF(ge.event_name = "newsletter_subscription",ge.new_eventId,NULL)) as nb_newsletter_subscription,

    -- # sessions (Corrigé avec EXISTS pour les catalogues)
    COUNT(DISTINCT IF(ge.event_name = "view_item_list", ge.ga_session_id, NULL)) AS nb_sessions_view_item,
    COUNT(DISTINCT IF(ge.event_name = "view_item_list" AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.ga_session_id, NULL)) AS nb_sessions_view_item_catalog,
    COUNT(DISTINCT IF(ge.event_name = "select_item", ge.ga_session_id, NULL)) AS nb_sessions_select_item,
    COUNT(DISTINCT IF(ge.event_name = "select_item"  AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.ga_session_id, NULL)) AS nb_sessions_select_item_catalog,
    --COUNT(DISTINCT IF(ge.event_name = "artist_subscription",ge.ga_session_id,NULL)) as nb_sessions_follow_artist,
    COUNT(DISTINCT IF(ge.event_name = "add_to_wishlist",ge.ga_session_id,NULL)) as nb_sessions_add_to_wishlist,
    COUNT(DISTINCT IF(ge.event_name = "make_an_offer_submit",ge.ga_session_id,NULL)) as nb_sessions_mao,
    COUNT(DISTINCT IF(ge.event_name = "add_to_cart",ge.ga_session_id,NULL)) as nb_sessions_add_to_cart,
    COUNT(DISTINCT IF(ge.event_name = "purchase",ge.ga_session_id,NULL)) as nb_sessions_purchase,
    --COUNT(DISTINCT IF(ge.event_name = "newsletter_subscription",ge.ga_session_id,NULL)) as nb_sessions_newsletter_subscription,

    -- BV estimate (Protégé de la duplication)
    SUM(IF(ge.event_name = "purchase",ge.event_value_in_usd*scr.rate,0)) as bv_eur_estimate,
    ge.device,
    COUNT(DISTINCT ge.visitor_id) as nb_sg_visitor_id
  FROM `singulart-data.ga_events.ga_events` ge
  -- LEFT JOIN UNNEST(ge.items) supprimé
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies_rates` scr on scr.base_id = 142 AND scr.target_id = 43
  WHERE ge.event_date >= "2026-02-25"
  AND ge.ga_session_id IS NOT NULL
  AND ge.ss_exp like "%211%"
  GROUP BY 1,2,ge.device
  ORDER BY 1,2,ge.device
), intra AS (
    SELECT
      ge.event_date,
      CASE
        WHEN ge.ss_exp LIKE "%211.0%" THEN "Control"
        WHEN ge.ss_exp LIKE "%211.1%" THEN "Test"
        ELSE "?"
      END as version,
      COUNT(DISTINCT ge.ga_session_id) as nb_ga_session_id,
      COUNT(DISTINCT IF(ge.session_engaged = 1,ge.ga_session_id,NULL)) as nb_sessions_engaged,
      COUNT(DISTINCT IF(ge.event_name = "session_start",ge.new_eventId,NULL)) as nb_sessions_start,

      -- # events (Corrigé avec UNNEST localisé)
      SUM(IF(ge.event_name = "view_item_list", (SELECT COUNT(DISTINCT CONCAT(IFNULL(i.item_id, 'null'), '-', IFNULL(i.item_list_index, 'null'))) FROM UNNEST(ge.items) i), 0)) AS nb_view_item,
      SUM(IF(ge.event_name = "view_item_list", (SELECT COUNT(DISTINCT CONCAT(IFNULL(i.item_id, 'null'), '-', IFNULL(i.item_list_index, 'null'))) FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), 0)) AS nb_view_item_catalog,
      COUNT(DISTINCT IF(ge.event_name = "select_item", ge.new_eventId, NULL)) AS nb_select_item,
      COUNT(DISTINCT IF(ge.event_name = "select_item" AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.new_eventId, NULL)) AS nb_select_item_catalog,
      --COUNT(DISTINCT IF(ge.event_name = "artist_subscription",ge.new_eventId,NULL)) as nb_follow_artist,
      COUNT(DISTINCT IF(ge.event_name = "add_to_wishlist",ge.new_eventId,NULL)) as nb_add_to_wishlist,
      COUNT(DISTINCT IF(ge.event_name = "make_an_offer_submit",ge.new_eventId,NULL)) as nb_mao,
      COUNT(DISTINCT IF(ge.event_name = "add_to_cart",ge.new_eventId,NULL)) as nb_add_to_cart,
      COUNT(DISTINCT IF(ge.event_name = "purchase",ge.new_eventId,NULL)) as nb_purchase,
      --COUNT(DISTINCT IF(ge.event_name = "newsletter_subscription",ge.new_eventId,NULL)) as nb_newsletter_subscription,

      -- # sessions (Corrigé avec EXISTS pour les catalogues)
      COUNT(DISTINCT IF(ge.event_name = "view_item_list", ge.ga_session_id, NULL)) AS nb_sessions_view_item,
      COUNT(DISTINCT IF(ge.event_name = "view_item_list" AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.ga_session_id, NULL)) AS nb_sessions_view_item_catalog,
      COUNT(DISTINCT IF(ge.event_name = "select_item", ge.ga_session_id, NULL)) AS nb_sessions_select_item,
      COUNT(DISTINCT IF(ge.event_name = "select_item" AND EXISTS(SELECT 1 FROM UNNEST(ge.items) i WHERE i.item_list_name IN ('sp', 'sp-r')), ge.ga_session_id, NULL)) AS nb_sessions_select_item_catalog,
      --COUNT(DISTINCT IF(ge.event_name = "artist_subscription",ge.ga_session_id,NULL)) as nb_sessions_follow_artist,
      COUNT(DISTINCT IF(ge.event_name = "add_to_wishlist",ge.ga_session_id,NULL)) as nb_sessions_add_to_wishlist,
      COUNT(DISTINCT IF(ge.event_name = "make_an_offer_submit",ge.ga_session_id,NULL)) as nb_sessions_mao,
      COUNT(DISTINCT IF(ge.event_name = "add_to_cart",ge.ga_session_id,NULL)) as nb_sessions_add_to_cart,
      COUNT(DISTINCT IF(ge.event_name = "purchase",ge.ga_session_id,NULL)) as nb_sessions_purchase,
      --COUNT(DISTINCT IF(ge.event_name = "newsletter_subscription",ge.ga_session_id,NULL)) as nb_sessions_newsletter_subscription,

      -- BV estimate (Protégé de la duplication)
      SUM(IF(ge.event_name = "purchase",ge.event_value_in_usd*scr.rate,0)) as bv_eur_estimate,
      ge.device,
      COUNT(DISTINCT ge.visitor_id) as nb_sg_visitor_id
    FROM `singulart-data.ga_events.ga_events_intraday` ge
    -- LEFT JOIN UNNEST(ge.items) supprimé
    INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies_rates` scr on scr.base_id = 142 AND scr.target_id = 43
    WHERE ge.event_date >= "2026-02-25"
    AND ge.ga_session_id IS NOT NULL
    AND ge.ss_exp like "%211%"
    GROUP BY 1,2,ge.device
    ORDER BY 1,2,ge.device
)

SELECT *
FROM non_intra

UNION ALL

SELECT *
FROM intra

ORDER BY event_date, version