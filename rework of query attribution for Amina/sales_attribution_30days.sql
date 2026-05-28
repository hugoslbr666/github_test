CREATE OR REPLACE TABLE `singulart-data.connected_sheets.sales_attribution_30days` as 
WITH vip as (
  SELECT 
    als.email
  FROM `singulart-data.connected_sheets.all_sales` als
  GROUP BY als.email
  HAVING sum(als.amount_eur_paid)  10000
),

email_first_uuid as (
  -- For first clicks, in cases where an email has two different uuid (and two different first clicks)
  -- This is can be due to multiple things, but mainly because most offlines sales are hard to attribute (because of sessions coming from sales advisors being linked to the sale)
  -- In those instances, we can just bypass the system, and rely on emails to make sure that at least each emails only has one first clickuuid
  -- This won't solve the problem for two emails belonging to the same physical person, but it'll be closer to the truth
  SELECT 
    als.email,
    ARRAY_AGG(va.uuid ORDER BY va.first_session_at LIMIT 1)[OFFSET(0)] as first_uuid
  FROM `singulart-data.connected_sheets.all_sales` als
  INNER JOIN `singulart-data.views.visitors_attribution_L30days` va on va.uuid = als.uuid
  GROUP BY als.email
),

all_sales as (
  SELECT 
    als.sale_id as sale_id,
    als.customer_order_number,
    als.customer_order_number_daily as customer_order_number_daily_model,
    ssip.heat,
    ssip.sale_type as bv_type,
    als.order_id as cartId,
    als.email,
    als.cik,
    efu.first_uuid,
    IF(v.email is not null,1,0) as VIP,
    als.paid_at,
    als.payment_mode,
    als.browsing_session_id,
    als.user_id as cartUserId,
    v1.locale as cartLocale,
    als.amount_eur_paid as purchaseEurAmountWithShipping, 
    als.delivery_price_eur,
    IF(als.customer_order_number  1, 1, 0) as isReturningBuyer,
    als.store_sale,
    als.b2b_sale,
    als.signature_sale,
    als.client as full_name,
    als.delivery_city as city,
    als.delivery_state as state,
    IF(als.payment_mode = 'offline', als.delivery_country, IFNULL(v1.country, als.delivery_country)) as country,
    CASE
        WHEN IF(als.payment_mode = 'offline', als.delivery_country, IFNULL(v1.country, als.delivery_country)) in (DE,AT,CH) THEN DACH
        WHEN IF(als.payment_mode = 'offline', als.delivery_country, IFNULL(v1.country, als.delivery_country)) in (US) THEN US
        WHEN IF(als.payment_mode = 'offline', als.delivery_country, IFNULL(v1.country, als.delivery_country)) in (JP,HK,SG,TW,KR) THEN ASIA
        WHEN IF(als.payment_mode = 'offline', als.delivery_country, IFNULL(v1.country, als.delivery_country)) in (FR,IT,ES) THEN FRITS
        ELSE OTHERS
    END as country_group,
    als.delivery_country as deliveryCountry, 
    v1.country as visitorCountryAtCartCreation,
    als.sale_type,
    als.artwork_id,
    als.addon_id,
    als.artist_id,
    als.artist as artist_name,
    als.artist_country,
    als.artwork_online_at,
    -- sa.online_at as artist_online_at,
    als.medium,
    als.universe,
    als.height_cm,
    als.width_cm,
    als.depth_cm,
    IFNULL(MIN(s2.id),als.browsing_session_id) as firstSessionId,
    -- For offline sales, the cart.sessionId is the last session id
    IFNULL(IF (als.payment_mode = 'offline', als.browsing_session_id, MAX(s2.id)),als.browsing_session_id) as lastSessionId
  FROM `singulart-data.connected_sheets.all_sales` als
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors` v1 on v1.id = als.visitor_id
  LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_sales_items_properties` ssip on ssip.sold_item_id = als.sale_id
  LEFT JOIN email_first_uuid efu on efu.email = als.email
  LEFT JOIN `singulart-data.views.visitor_attribution_L30days` va on va.uuid = efu.first_uuid
  LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` s2 ON s2.visitor_id = va.visitor_id AND s2.created_at  als.paid_at
  LEFT JOIN vip v on v.email = als.email
  WHERE paid_at IS NOT NULL
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40
)


SELECT
    a.,
    vFirstCik.country as first_click_country,
    FORMAT_DATE('%Y%m',a.paid_at) paid_at_YYYYMM,
    FORMAT_DATE('%Y%m%d',a.paid_at) paid_at_YYYYMMDD,
    FORMAT_DATE('%Y%m%d',DATE_TRUNC(a.paid_at,WEEK(MONDAY))) paid_at_WW,
    -- First session info
    sFirstCik.created_at as email_1st_click_at,
    FORMAT_DATE('%Y%m%d',sFirstCik.created_at) AS email_1st_click_at_YYYYMMDD,
    FORMAT_DATE('%Y%m',sFirstCik.created_at) AS email_1st_email_click_at_YYYYMM,
    FORMAT_DATE('%Y%m%d',DATE_TRUNC(sFirstCik.created_at,WEEK(MONDAY))) AS email_1st_email_click_at_WW,
    
    CASE 
    WHEN LOWER(vFirstCik.user_agent) like %iphone% or LOWER(vFirstCik.user_agent) like %android% then mobile
    WHEN LOWER(vFirstCik.user_agent) like %macintosh% or LOWER(vFirstCik.user_agent) like %windows% or LOWER(vFirstCik.user_agent) like %linux% or LOWER(vFirstCik.user_agent) like %x11; cros% then desktop
    WHEN LOWER(vFirstCik.user_agent) like %ipad% then tablet
    ELSE other 
END
     as email_1st_device, 
    cFirst.campaign_id AS email_1st_click_campaign_id,
    cFirst.campaign AS email_1st_click_campaign_name,
    cFirst.source AS email_1st_click_source_name,
    cFirst.channel AS email_1st_click_channel_name,
    cFirst.channel_group AS email_1st_click_channel_group_name,
    srFirst.referer as email_1st_click_referer,
    srFirst.landing_page as email_1st_click_landing_page,
    srFirst.landing_tpl as email_1st_click_landing_tpl,
    srFirst.landing_object_id as email_1st_click_landing_object_id,
    -- Last session info
    sLastCik.created_at as emailLast_click_at,
    FORMAT_DATE('%Y%m%d',sLastCik.created_at) AS emailLast_click_at_YYYYMMDD,
    FORMAT_DATE('%Y%m',sLastCik.created_at) AS emailLast_click_at_YYYYMM,
    FORMAT_DATE('%Y%m%d',DATE_TRUNC(sLastCik.created_at,WEEK(MONDAY))) AS emailLast_email_click_at_WW,
    
    CASE 
    WHEN LOWER(vLastCik.user_agent) like %iphone% or LOWER(vLastCik.user_agent) like %android% then mobile
    WHEN LOWER(vLastCik.user_agent) like %macintosh% or LOWER(vLastCik.user_agent) like %windows% or LOWER(vLastCik.user_agent) like %linux% or LOWER(vLastCik.user_agent) like %x11; cros% then desktop
    WHEN LOWER(vLastCik.user_agent) like %ipad% then tablet
    ELSE other 
END
     as email_last_device, 
    cLast.campaign_id AS emailLast_click_campaign_id,
    cLast.campaign AS emailLast_click_campaign_name,
    cLast.source AS emailLast_click_source_name,
    cLast.channel AS emailLast_click_channel_name,
    cLast.channel_group AS emailLast_click_channel_group_name,
    srLast.referer as emailLast_click_referer,
    srLast.landing_page as emailLast_click_landing_page,
    srLast.landing_tpl as emailLast_click_landing_tpl,
    srLast.landing_object_id as email_last_click_landing_object_id,
    TIMESTAMP_DIFF(paid_at, sFirstCik.created_at,HOUR)24 as emailDaysFirstClickToPurchase,
    CURRENT_DATETIME(EuropeParis) as last_update_at
    FROM all_sales a
    -- First session info
    LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` sFirstCik ON sFirstCik.id = a.firstSessionId
    LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors` vFirstCik on vFirstCik.id = sFirstCik.visitor_id
    LEFT JOIN `singulart-data.views.campaigns` cFirst on cFirst.campaign_id = sFirstCik.tracking_campaign_id
    LEFT JOIN `singulart-data.views.session_referer` srFirst on srFirst.session_id = a.firstSessionId
    -- Last session info
    LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` sLastCik ON sLastCik.id = a.lastSessionId
    LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors` vLastCik on vLastCik.id = sLastCik.visitor_id
    LEFT JOIN `singulart-data.views.campaigns` cLast on cLast.campaign_id = sLastCik.tracking_campaign_id
    LEFT JOIN `singulart-data.views.session_referer` srLast on srLast.session_id = a.lastSessionId
    ORDER BY a.sale_id DESC