-- Change the days attribution windows By changing the days intervals in line 20

CREATE OR REPLACE TABLE `singulart-data.views.visitor_attribution_L30days` AS
WITH

-- ============================================================
-- Step 1: Session aggregates — filtered to last 30 days
--         (visitors_attribution_sessions_agg)
-- ============================================================
sessions_agg AS (
  SELECT
    visitor_id,
    ARRAY_AGG(id ORDER BY created_at LIMIT 1)[SAFE_OFFSET(0)]                                    AS first_session_id,
    ARRAY_AGG(tracking_campaign_id IGNORE NULLS ORDER BY created_at LIMIT 1)[SAFE_OFFSET(0)]     AS first_campaign_id,
    ARRAY_AGG(created_at IGNORE NULLS ORDER BY created_at LIMIT 1)[SAFE_OFFSET(0)]               AS first_session_at,
    ARRAY_AGG(id ORDER BY created_at DESC LIMIT 1)[SAFE_OFFSET(0)]                               AS last_session_id,
    ARRAY_AGG(tracking_campaign_id IGNORE NULLS ORDER BY created_at DESC LIMIT 1)[SAFE_OFFSET(0)] AS last_campaign_id,
    ARRAY_AGG(created_at IGNORE NULLS ORDER BY created_at DESC LIMIT 1)[SAFE_OFFSET(0)]          AS last_session_at
  FROM `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions`
  WHERE created_at >= date_sub(current_date(), INTERVAL 30 DAY)
  GROUP BY visitor_id
),

-- ============================================================
-- Step 2: CIK-level attribution
--         (inner CTE of visitors_attribution_base_materialized)
-- ============================================================
cik_attribution AS (
  SELECT
    stc.cik,
    ARRAY_AGG(stv.country IGNORE NULLS ORDER BY vsa.first_session_at LIMIT 1)[SAFE_OFFSET(0)]           AS first_country,
    ARRAY_AGG(vsa.first_session_id ORDER BY vsa.first_session_at LIMIT 1)[SAFE_OFFSET(0)]               AS first_session_id,
    ARRAY_AGG(vsa.first_campaign_id IGNORE NULLS ORDER BY vsa.first_session_at LIMIT 1)[SAFE_OFFSET(0)] AS first_campaign_id,
    ARRAY_AGG(vsa.first_session_at IGNORE NULLS ORDER BY vsa.first_session_at LIMIT 1)[SAFE_OFFSET(0)]  AS first_session_at,
    ARRAY_AGG(vsa.last_session_id ORDER BY vsa.last_session_at DESC LIMIT 1)[SAFE_OFFSET(0)]            AS last_session_id,
    ARRAY_AGG(vsa.last_campaign_id IGNORE NULLS ORDER BY vsa.last_session_at DESC LIMIT 1)[SAFE_OFFSET(0)] AS last_campaign_id,
    ARRAY_AGG(vsa.last_session_at IGNORE NULLS ORDER BY vsa.last_session_at DESC LIMIT 1)[SAFE_OFFSET(0)]  AS last_session_at,
    ARRAY_AGG(stv.locale IGNORE NULLS ORDER BY vsa.last_session_at DESC LIMIT 1)[SAFE_OFFSET(0)]        AS last_locale
  FROM `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors` stv
  INNER JOIN `singulart-db-to-bigquery.data_playground.sgt_tracking_ciks` stc ON stc.visitor_id = stv.id
  INNER JOIN sessions_agg vsa ON vsa.visitor_id = stv.id
  GROUP BY 1
),

-- ============================================================
-- Step 3: Base materialized
--         (visitors_attribution_base_materialized)
-- ============================================================
base_materialized AS (
  -- CIK-linked visitors
  SELECT
    stc.cik AS uuid,
    ARRAY_AGG(DISTINCT stv.id ORDER BY stv.id)          AS visitor_ids,
    ARRAY_AGG(DISTINCT stu.id IGNORE NULLS ORDER BY stu.id) AS user_ids,
    ARRAY_AGG(DISTINCT stu.uuid IGNORE NULLS)           AS uuid_ids,
    MAX(IF(bvi.visitor_id IS NOT NULL, 1, 0))           AS bot,
    MAX(IF(bev.visitor_id IS NOT NULL, 1, 0))           AS b2b_enrolled,
    MAX(IF(svi.visitor_id IS NOT NULL, 1, 0))           AS singulart,
    MAX(IF(stcb.visitor_id IS NOT NULL, 1, 0))          AS blacklisted,
    cf.first_country,
    cf.last_locale,
    cf.first_session_id,
    cf.first_campaign_id,
    cf.first_session_at,
    cf.last_session_id,
    cf.last_campaign_id,
    cf.last_session_at,
    cfo.first_order_at,
    cfo.last_order_at
  FROM `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors` stv
  INNER JOIN `singulart-db-to-bigquery.data_playground.sgt_tracking_ciks` stc ON stc.visitor_id = stv.id
  INNER JOIN cik_attribution cf ON cf.cik = stc.cik
  LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_users` stu ON stu.id = stv.user_id
  LEFT JOIN `singulart-db-to-bigquery.data_playground.sgt_tracking_ciks_blacklist` stcb ON stcb.visitor_id = stv.id
  LEFT JOIN `singulart-data.tech.visitors_attribution_uuid_first_order` cfo ON cfo.cik = stc.cik
  LEFT JOIN `singulart-data.views.bot_visitor_ids` bvi ON bvi.visitor_id = stv.id
  LEFT JOIN `singulart-data.views.b2b_enrolled_visitor_ids` bev ON bev.visitor_id = stv.id
  LEFT JOIN `singulart-data.views.singulart_visitor_ids` svi ON svi.visitor_id = stv.id
  GROUP BY
    stc.cik, cf.first_country, cf.last_locale,
    cf.first_session_id, cf.first_campaign_id, cf.first_session_at,
    cf.last_session_id, cf.last_campaign_id, cf.last_session_at,
    cfo.first_order_at, cfo.last_order_at

  UNION ALL

  -- Anonymous visitors (no CIK)
  SELECT
    CONCAT('v-', stv.id) AS uuid,
    ARRAY_AGG(stv.id ORDER BY stv.id LIMIT 1)               AS visitor_ids,
    ARRAY_AGG(DISTINCT stu.id IGNORE NULLS ORDER BY stu.id) AS user_ids,
    ARRAY_AGG(DISTINCT stu.uuid IGNORE NULLS)               AS uuid_ids,
    IF(bvi.visitor_id IS NOT NULL, 1, 0)                    AS bot,
    MAX(IF(bev.visitor_id IS NOT NULL, 1, 0))               AS b2b_enrolled,
    MAX(IF(svi.visitor_id IS NOT NULL, 1, 0))               AS singulart,
    MAX(IF(stcb.visitor_id IS NOT NULL, 1, 0))              AS blacklisted,
    stv.country AS first_country,
    stv.locale  AS last_locale,
    vsa.first_session_id,
    vsa.first_campaign_id,
    vsa.first_session_at,
    vsa.last_session_id,
    vsa.last_campaign_id,
    vsa.last_session_at,
    vfo.first_order_at,
    vfo.last_order_at
  FROM `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors` stv
  INNER JOIN sessions_agg vsa ON vsa.visitor_id = stv.id
  LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_users` stu ON stu.id = stv.user_id
  LEFT JOIN `singulart-db-to-bigquery.data_playground.sgt_tracking_ciks` stc ON stc.visitor_id = stv.id
  LEFT JOIN `singulart-db-to-bigquery.data_playground.sgt_tracking_ciks_blacklist` stcb ON stcb.visitor_id = stv.id
  LEFT JOIN `singulart-data.tech.visitors_attribution_uuid_first_order` vfo ON vfo.uuid = SAFE_CAST(stv.id AS STRING)
  LEFT JOIN `singulart-data.views.bot_visitor_ids` bvi ON bvi.visitor_id = stv.id
  LEFT JOIN `singulart-data.views.b2b_enrolled_visitor_ids` bev ON bev.visitor_id = stv.id
  LEFT JOIN `singulart-data.views.singulart_visitor_ids` svi ON svi.visitor_id = stv.id
  WHERE stc.cik IS NULL
  GROUP BY
    stv.id, bot, stv.country, stv.locale,
    vsa.first_session_id, vsa.first_campaign_id, vsa.first_session_at,
    vsa.last_session_id, vsa.last_campaign_id, vsa.last_session_at,
    vfo.first_order_at, vfo.last_order_at
),

-- ============================================================
-- Step 4: Email enrichment
--         (visitors_attribution_email_enrichment)
-- ============================================================
email_enrichment AS (
  SELECT
    b.uuid,
    ARRAY_AGG(DISTINCT stue.customer_id IGNORE NULLS ORDER BY stue.customer_id)          AS customer_ids,
    ARRAY_AGG(DISTINCT LOWER(stue.email) IGNORE NULLS ORDER BY LOWER(stue.email))        AS emails
  FROM base_materialized b
  CROSS JOIN UNNEST(b.user_ids) AS uid
  LEFT JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_users_emails` stue ON stue.user_id = uid
  GROUP BY b.uuid
),

-- ============================================================
-- Final output
-- (visitors_attribution)
-- ============================================================
final as (
SELECT
  b.*,
  e.customer_ids,
  e.emails
FROM base_materialized b
LEFT JOIN email_enrichment e ON e.uuid = b.uuid
)

select
*
from final, unnest(visitor_ids) as visitor_id