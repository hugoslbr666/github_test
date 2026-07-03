-- =============================================================================
-- PROMOTION PERFORMANCE ANALYSIS
-- =============================================================================
-- Purpose   : Compare promotion formats on a normalized per-day basis so
--             longer promos don't win by volume alone.
-- Date range: 2025-01-01 → end of promotions calendar
-- Sources   :
--   • singulart-datasandbox.hugo.temp_promotions_calendar  (promo schedule)
--   • singulart-data.ga_events.ga_events                   (impressions)
--   • singulart-data.views.all_pageviews                   (artwork clicks)
--   • singulart-data.connected_sheets.all_sales            (sales / BV)
--   • singulart-data.reporting.engaged_visitor_ids         (visitor filter)
--
-- All metrics (impressions, clicks, sessions, sales) are restricted to engaged visitors,
-- defined as visitors with at least one session of >2 humanlike pageviews.
--
-- NOTE: Discounted impressions data only exists from 2026-02-12.
--       All metrics relying on discounted_impressions will be NULL for promos
--       that predate that cutoff. See days_with_disc_imp_data in promo_summary.
--
-- USAGE: Five output options are at the bottom. Uncomment the one you want.
-- =============================================================================

WITH

-- ── 1. PROMOTIONS CALENDAR ───────────────────────────────────────────────────
-- Derives format, day-within-promo number, and duration from promotion_name.
-- promo_calendar_raw computes window functions on the raw name (including '-'
-- for non-promo days), then promo_calendar nullifies non-promo rows.

promo_calendar_raw AS (
  SELECT
    CAST(Date AS DATE) AS date,
    is_promotion,
    promotion_name,
    ROW_NUMBER() OVER (PARTITION BY promotion_name ORDER BY CAST(Date AS DATE)) AS promo_day_number,
    COUNT(*)           OVER (PARTITION BY promotion_name)                        AS promo_duration,
    MIN(CAST(Date AS DATE)) OVER (PARTITION BY promotion_name)                   AS promo_start_date,
    MAX(CAST(Date AS DATE)) OVER (PARTITION BY promotion_name)                   AS promo_end_date
  FROM `singulart-datasandbox.hugo.temp_promotions_calendar`
),

promo_calendar AS (
  SELECT
    date,
    is_promotion,
    CASE WHEN is_promotion = 0 THEN NULL ELSE promotion_name   END AS promotion_name,
    CASE WHEN is_promotion = 0 THEN NULL
         WHEN promotion_name LIKE '%WKND%'   THEN 'weekend'   -- 3 days
         WHEN promotion_name LIKE '%4DAYS%'  THEN '4_days'
         WHEN promotion_name LIKE '%1WEEK%'  THEN '1_week'    -- 7 days
         WHEN promotion_name LIKE '%8DAYS%'  THEN '8_days'
         WHEN promotion_name LIKE '%10DAYS%' THEN '10_days'
         WHEN promotion_name LIKE '%3WEEK%'  THEN '3_weeks'   -- 21 days
    END                                                         AS promo_format,
    CASE WHEN is_promotion = 0 THEN NULL ELSE promo_day_number END AS promo_day_number,
    CASE WHEN is_promotion = 0 THEN NULL ELSE promo_duration   END AS promo_duration,
    CASE WHEN is_promotion = 0 THEN NULL ELSE promo_start_date END AS promo_start_date,
    CASE WHEN is_promotion = 0 THEN NULL ELSE promo_end_date   END AS promo_end_date
  FROM promo_calendar_raw
),

-- ── 2. DAILY IMPRESSIONS ─────────────────────────────────────────────────────
-- total_impressions     : all view_item_list events, deduplicated by
--                         (event, item, position) to avoid double-counting.
-- discounted_impressions: same events where the item carried a discount
--                         AND the session coupon was 'singulart_sales'.
-- Restricted to engaged visitors only.

daily_impressions AS (
  SELECT
    ge.event_date,
    COUNT(DISTINCT CONCAT(ge.new_eventId, '-', items.item_id, '-', items.item_list_index))
      AS total_impressions,
    COUNT(DISTINCT IF(
      items.discount_value_usd > 0 AND items.coupon = 'singulart_sales',
      CONCAT(ge.new_eventId, '-', items.item_id, '-', items.item_list_index),
      NULL
    )) AS discounted_impressions,
    -- new buyer: never bought OR session on/before first purchase date
    COUNT(DISTINCT IF(
      va.first_order_at IS NULL OR ge.event_date <= DATE(va.first_order_at),
      CONCAT(ge.new_eventId, '-', items.item_id, '-', items.item_list_index),
      NULL
    )) AS total_impressions_new,
    COUNT(DISTINCT IF(
      va.first_order_at IS NOT NULL AND ge.event_date > DATE(va.first_order_at),
      CONCAT(ge.new_eventId, '-', items.item_id, '-', items.item_list_index),
      NULL
    )) AS total_impressions_returning,
    COUNT(DISTINCT IF(
      items.discount_value_usd > 0 AND items.coupon = 'singulart_sales'
        AND (va.first_order_at IS NULL OR ge.event_date <= DATE(va.first_order_at)),
      CONCAT(ge.new_eventId, '-', items.item_id, '-', items.item_list_index),
      NULL
    )) AS discounted_impressions_new,
    COUNT(DISTINCT IF(
      items.discount_value_usd > 0 AND items.coupon = 'singulart_sales'
        AND va.first_order_at IS NOT NULL AND ge.event_date > DATE(va.first_order_at),
      CONCAT(ge.new_eventId, '-', items.item_id, '-', items.item_list_index),
      NULL
    )) AS discounted_impressions_returning
  FROM `singulart-data.ga_events.ga_events` ge
  CROSS JOIN UNNEST(items) AS items
  INNER JOIN `singulart-data.reporting.engaged_visitor_ids` ev ON ev.visitor_id = ge.visitor_id
  LEFT  JOIN `singulart-data.views.visitor_attribution`    va  ON va.visitor_id = ge.visitor_id
  WHERE ge.event_name = 'view_item_list'
    AND ge.event_date >= '2025-01-01'
  GROUP BY 1
),

-- ── 3. DAILY ARTWORK CLICKS ──────────────────────────────────────────────────
-- Each row in all_pageviews with tpl = 'artwork' is one artwork page visit.
-- Joins through sgt_tracking_visitors_sessions to resolve visitor_id,
-- then filters to engaged visitors only.

daily_clicks AS (
  SELECT
    DATE(ap.created_at) AS date,
    COUNT(*)            AS nb_artwork_clicks,
    COUNTIF(va.first_order_at IS NULL OR DATE(ap.created_at) <= DATE(va.first_order_at))
      AS nb_clicks_new,
    COUNTIF(va.first_order_at IS NOT NULL AND DATE(ap.created_at) > DATE(va.first_order_at))
      AS nb_clicks_returning
  FROM `singulart-data.views.all_pageviews` ap
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs
    ON stvs.id = ap.session_id
  INNER JOIN `singulart-data.reporting.engaged_visitor_ids` ev
    ON ev.visitor_id = stvs.visitor_id
  LEFT  JOIN `singulart-data.views.visitor_attribution`    va
    ON va.visitor_id = stvs.visitor_id
  WHERE ap.tpl = 'artwork'
    AND DATE(ap.created_at) >= '2025-01-01'
  GROUP BY 1
),

-- ── 4. DAILY SALES & BV ──────────────────────────────────────────────────────
-- Artwork/piece sales only — excludes framing, addons, commissions.
-- BV = amount_eur_paid. Restricted to engaged visitors only.
--
-- first_order_at from visitors_attribution defines buyer type:
--   new       = sale date matches first_order_at date (first-ever purchase)
--   returning = sale date is after first_order_at date
-- LEFT JOIN so that sales from visitors absent in visitors_attribution are
-- still counted in units_sold / bv totals, but excluded from the new/returning split.

daily_sales AS (
  SELECT
    DATE(s.paid_at)           AS date,
    COUNT(DISTINCT s.sale_id) AS units_sold,
    COUNT(DISTINCT IF(DATE(s.paid_at) = DATE(va.first_order_at), s.sale_id, NULL)) AS units_sold_new,
    COUNT(DISTINCT IF(DATE(s.paid_at) > DATE(va.first_order_at), s.sale_id, NULL)) AS units_sold_returning,
    ROUND(SUM(s.amount_eur_paid), 2)                                                 AS bv,
    ROUND(SUM(IF(DATE(s.paid_at) = DATE(va.first_order_at), s.amount_eur_paid, 0)), 2) AS bv_new,
    ROUND(SUM(IF(DATE(s.paid_at) > DATE(va.first_order_at), s.amount_eur_paid, 0)), 2) AS bv_returning
  FROM `singulart-data.connected_sheets.all_sales` s
  INNER JOIN `singulart-data.reporting.engaged_visitor_ids` ev ON ev.visitor_id = s.visitor_id
  LEFT  JOIN `singulart-data.views.visitor_attribution`    va  ON va.visitor_id = s.visitor_id
  WHERE s.sale_type = 'artwork/piece'
    AND DATE(s.paid_at) >= '2025-01-01'
  GROUP BY 1
),

-- ── 5. DAILY SESSIONS ────────────────────────────────────────────────────────
-- Count of distinct sessions from engaged visitors only.
-- One session = one row in sgt_tracking_visitors_sessions with a matching
-- visitor_id in engaged_visitor_ids.

daily_sessions AS (
  SELECT
    DATE(stvs.created_at)   AS date,
    COUNT(DISTINCT stvs.id) AS nb_sessions,
    COUNT(DISTINCT IF(
      va.first_order_at IS NULL OR DATE(stvs.created_at) <= DATE(va.first_order_at),
      stvs.id, NULL
    )) AS nb_sessions_new,
    COUNT(DISTINCT IF(
      va.first_order_at IS NOT NULL AND DATE(stvs.created_at) > DATE(va.first_order_at),
      stvs.id, NULL
    )) AS nb_sessions_returning
  FROM `singulart-db-to-bigquery.singulartdb.sgt_tracking_visitors_sessions` stvs
  INNER JOIN `singulart-data.reporting.engaged_visitor_ids` ev
    ON ev.visitor_id = stvs.visitor_id
  LEFT  JOIN `singulart-data.views.visitor_attribution`    va
    ON va.visitor_id = stvs.visitor_id
  WHERE DATE(stvs.created_at) >= '2025-01-01'
  GROUP BY 1
),

-- ── 6. BASE: ONE ROW PER DAY ─────────────────────────────────────────────────
-- The promo calendar drives the date spine.
-- Promo columns are NULL on non-promo days.
-- discounted_impressions is NULL before 2026-02-12 (data unavailable).

promo_daily_metrics AS (
  SELECT
    pc.date,
    pc.is_promotion,
    pc.promotion_name,
    pc.promo_format,
    pc.promo_day_number,
    pc.promo_duration,
    pc.promo_start_date,
    pc.promo_end_date,
    COALESCE(di.total_impressions, 0)             AS total_impressions,
    COALESCE(di.total_impressions_new, 0)         AS total_impressions_new,
    COALESCE(di.total_impressions_returning, 0)   AS total_impressions_returning,
    IF(pc.date >= '2026-02-12',
       COALESCE(di.discounted_impressions, 0),
       NULL)                                       AS discounted_impressions,
    IF(pc.date >= '2026-02-12',
       COALESCE(di.discounted_impressions_new, 0),
       NULL)                                       AS discounted_impressions_new,
    IF(pc.date >= '2026-02-12',
       COALESCE(di.discounted_impressions_returning, 0),
       NULL)                                       AS discounted_impressions_returning,
    COALESCE(dc.nb_artwork_clicks, 0)             AS nb_artwork_clicks,
    COALESCE(dc.nb_clicks_new, 0)                 AS nb_clicks_new,
    COALESCE(dc.nb_clicks_returning, 0)           AS nb_clicks_returning,
    COALESCE(sess.nb_sessions, 0)                 AS nb_sessions,
    COALESCE(sess.nb_sessions_new, 0)             AS nb_sessions_new,
    COALESCE(sess.nb_sessions_returning, 0)       AS nb_sessions_returning,
    COALESCE(ds.units_sold, 0)                    AS units_sold,
    COALESCE(ds.units_sold_new, 0)                AS units_sold_new,
    COALESCE(ds.units_sold_returning, 0)          AS units_sold_returning,
    COALESCE(ds.bv, 0)                            AS bv,
    COALESCE(ds.bv_new, 0)                        AS bv_new,
    COALESCE(ds.bv_returning, 0)                  AS bv_returning
  FROM promo_calendar pc
  LEFT JOIN daily_impressions di   ON di.event_date = pc.date
  LEFT JOIN daily_clicks      dc   ON dc.date        = pc.date
  LEFT JOIN daily_sessions    sess ON sess.date       = pc.date
  LEFT JOIN daily_sales       ds   ON ds.date         = pc.date
),

-- ── 7. PER-PROMO SUMMARY ─────────────────────────────────────────────────────
-- Totals + per-day averages (duration-normalised) + conversion metrics.
-- days_with_disc_imp_data: how many of the promo's days have discounted
-- impression data — use this to judge whether conversion metrics are reliable.

promo_summary AS (
  SELECT
    promotion_name,
    promo_format,
    promo_start_date,
    promo_end_date,
    promo_duration,
    COUNTIF(discounted_impressions IS NOT NULL) AS days_with_disc_imp_data,

    -- Totals
    SUM(total_impressions)              AS total_impressions,
    SUM(total_impressions_new)          AS total_impressions_new,
    SUM(total_impressions_returning)    AS total_impressions_returning,
    SUM(discounted_impressions)         AS discounted_impressions,
    SUM(discounted_impressions_new)     AS discounted_impressions_new,
    SUM(discounted_impressions_returning) AS discounted_impressions_returning,
    SUM(nb_artwork_clicks)              AS nb_artwork_clicks,
    SUM(nb_clicks_new)                  AS nb_clicks_new,
    SUM(nb_clicks_returning)            AS nb_clicks_returning,
    SUM(nb_sessions)                    AS nb_sessions,
    SUM(nb_sessions_new)                AS nb_sessions_new,
    SUM(nb_sessions_returning)          AS nb_sessions_returning,
    SUM(units_sold)                     AS units_sold,
    SUM(units_sold_new)                 AS units_sold_new,
    SUM(units_sold_returning)           AS units_sold_returning,
    SUM(bv)                             AS bv,
    SUM(bv_new)                         AS bv_new,
    SUM(bv_returning)                   AS bv_returning,

    -- Per-day averages (key metric for cross-format comparison)
    ROUND(SUM(total_impressions)            / promo_duration, 1) AS impressions_per_day,
    ROUND(SUM(total_impressions_new)        / promo_duration, 1) AS impressions_new_per_day,
    ROUND(SUM(total_impressions_returning)  / promo_duration, 1) AS impressions_returning_per_day,
    ROUND(SAFE_DIVIDE(SUM(discounted_impressions),           promo_duration), 1) AS disc_impressions_per_day,
    ROUND(SAFE_DIVIDE(SUM(discounted_impressions_new),       promo_duration), 1) AS disc_impressions_new_per_day,
    ROUND(SAFE_DIVIDE(SUM(discounted_impressions_returning), promo_duration), 1) AS disc_impressions_returning_per_day,
    ROUND(SUM(nb_artwork_clicks)            / promo_duration, 1) AS clicks_per_day,
    ROUND(SUM(nb_clicks_new)                / promo_duration, 1) AS clicks_new_per_day,
    ROUND(SUM(nb_clicks_returning)          / promo_duration, 1) AS clicks_returning_per_day,
    ROUND(SUM(nb_sessions)                  / promo_duration, 1) AS sessions_per_day,
    ROUND(SUM(nb_sessions_new)              / promo_duration, 1) AS sessions_new_per_day,
    ROUND(SUM(nb_sessions_returning)        / promo_duration, 1) AS sessions_returning_per_day,
    ROUND(SUM(units_sold)                   / promo_duration, 3) AS units_sold_per_day,
    ROUND(SUM(units_sold_new)               / promo_duration, 3) AS units_new_per_day,
    ROUND(SUM(units_sold_returning)         / promo_duration, 3) AS units_returning_per_day,
    ROUND(SUM(bv)                           / promo_duration, 2) AS bv_per_day,
    ROUND(SUM(bv_new)                       / promo_duration, 2) AS bv_new_per_day,
    ROUND(SUM(bv_returning)                 / promo_duration, 2) AS bv_returning_per_day,

    -- Buyer-type split (sessions and units)
    ROUND(SAFE_DIVIDE(SUM(nb_sessions_returning),  SUM(nb_sessions))  * 100, 1) AS pct_sessions_returning,
    ROUND(SAFE_DIVIDE(SUM(units_sold_returning),   SUM(units_sold))   * 100, 1) AS pct_returning,

    -- Conversion metrics — each buyer type uses its own session denominator
    ROUND(SAFE_DIVIDE(SUM(units_sold),          SUM(nb_sessions)),          6) AS conv_rate,
    ROUND(SAFE_DIVIDE(SUM(units_sold_new),       SUM(nb_sessions_new)),      6) AS conv_rate_new,
    ROUND(SAFE_DIVIDE(SUM(units_sold_returning), SUM(nb_sessions_returning)), 6) AS conv_rate_returning,
    ROUND(SAFE_DIVIDE(SUM(bv), SUM(total_impressions)),          4) AS bv_per_total_imp,
    ROUND(SAFE_DIVIDE(SUM(bv), SUM(discounted_impressions)),     4) AS bv_per_disc_imp
  FROM promo_daily_metrics
  WHERE is_promotion = 1
  GROUP BY promotion_name, promo_format, promo_start_date, promo_end_date, promo_duration
),

-- ── 8. DECAY CURVE ───────────────────────────────────────────────────────────
-- One row per (promo × day_number) to visualize how metrics evolve day by day.
-- Plot promo_day_number on x-axis, split lines by promotion_name or promo_format.

promo_decay_curve AS (
  SELECT
    promotion_name,
    promo_format,
    promo_duration,
    promo_day_number,
    date,
    total_impressions,
    total_impressions_new,
    total_impressions_returning,
    discounted_impressions,
    discounted_impressions_new,
    discounted_impressions_returning,
    nb_artwork_clicks,
    nb_clicks_new,
    nb_clicks_returning,
    nb_sessions,
    nb_sessions_new,
    nb_sessions_returning,
    units_sold,
    units_sold_new,
    units_sold_returning,
    bv,
    bv_new,
    bv_returning,
    ROUND(SAFE_DIVIDE(units_sold,           nb_sessions),           6) AS daily_conv_rate,
    ROUND(SAFE_DIVIDE(units_sold_new,        nb_sessions_new),       6) AS daily_conv_rate_new,
    ROUND(SAFE_DIVIDE(units_sold_returning,  nb_sessions_returning),  6) AS daily_conv_rate_returning,
    ROUND(SAFE_DIVIDE(bv, total_impressions), 4)                         AS daily_bv_per_impression
  FROM promo_daily_metrics
  WHERE is_promotion = 1
),

-- ── 9. MONTHLY BASELINE (non-promo days) ─────────────────────────────────────
-- Average daily metrics on non-promo days, grouped by month.
-- Lift = promo metric / baseline metric for the same month.

promo_baseline AS (
  SELECT
    DATE_TRUNC(date, MONTH)         AS month,
    COUNT(*)                         AS nb_baseline_days,
    ROUND(AVG(total_impressions), 1)           AS avg_daily_impressions,
    ROUND(AVG(total_impressions_new), 1)       AS avg_daily_impressions_new,
    ROUND(AVG(total_impressions_returning), 1) AS avg_daily_impressions_returning,
    ROUND(AVG(nb_artwork_clicks), 1)           AS avg_daily_clicks,
    ROUND(AVG(nb_clicks_new), 1)               AS avg_daily_clicks_new,
    ROUND(AVG(nb_clicks_returning), 1)         AS avg_daily_clicks_returning,
    ROUND(AVG(nb_sessions), 1)                 AS avg_daily_sessions,
    ROUND(AVG(nb_sessions_new), 1)             AS avg_daily_sessions_new,
    ROUND(AVG(nb_sessions_returning), 1)       AS avg_daily_sessions_returning,
    ROUND(AVG(units_sold), 3)                  AS avg_daily_units_sold,
    ROUND(AVG(units_sold_new), 3)              AS avg_daily_units_new,
    ROUND(AVG(units_sold_returning), 3)        AS avg_daily_units_returning,
    ROUND(AVG(bv), 2)                          AS avg_daily_bv,
    ROUND(AVG(bv_new), 2)                      AS avg_daily_bv_new,
    ROUND(AVG(bv_returning), 2)                AS avg_daily_bv_returning
  FROM promo_daily_metrics
  WHERE is_promotion = 0
  GROUP BY 1
),

-- ── 10. FORMAT SUMMARY ───────────────────────────────────────────────────────
-- Aggregate across all promos of the same format: mean, median, n.
-- months_covered lets you spot seasonality confounds
-- (e.g. if 3_weeks promos cluster around Nov/Dec).

promo_format_summary AS (
  SELECT
    promo_format,
    COUNT(*) AS n_promos,

    -- Mean (per-day normalised)
    ROUND(AVG(impressions_per_day),              1) AS mean_impressions_per_day,
    ROUND(AVG(impressions_new_per_day),          1) AS mean_impressions_new_per_day,
    ROUND(AVG(impressions_returning_per_day),    1) AS mean_impressions_returning_per_day,
    ROUND(AVG(disc_impressions_per_day),         1) AS mean_disc_impressions_per_day,
    ROUND(AVG(disc_impressions_new_per_day),     1) AS mean_disc_impressions_new_per_day,
    ROUND(AVG(disc_impressions_returning_per_day), 1) AS mean_disc_impressions_returning_per_day,
    ROUND(AVG(clicks_per_day),                   1) AS mean_clicks_per_day,
    ROUND(AVG(clicks_new_per_day),               1) AS mean_clicks_new_per_day,
    ROUND(AVG(clicks_returning_per_day),         1) AS mean_clicks_returning_per_day,
    ROUND(AVG(sessions_per_day),                 1) AS mean_sessions_per_day,
    ROUND(AVG(sessions_new_per_day),             1) AS mean_sessions_new_per_day,
    ROUND(AVG(sessions_returning_per_day),       1) AS mean_sessions_returning_per_day,
    ROUND(AVG(units_sold_per_day),               3) AS mean_units_sold_per_day,
    ROUND(AVG(units_new_per_day),                3) AS mean_units_new_per_day,
    ROUND(AVG(units_returning_per_day),          3) AS mean_units_returning_per_day,
    ROUND(AVG(bv_per_day),                       2) AS mean_bv_per_day,
    ROUND(AVG(bv_new_per_day),                   2) AS mean_bv_new_per_day,
    ROUND(AVG(bv_returning_per_day),             2) AS mean_bv_returning_per_day,

    -- Median (per-day normalised — total only, for conciseness)
    ROUND(APPROX_QUANTILES(impressions_per_day,      2)[OFFSET(1)], 1) AS median_impressions_per_day,
    ROUND(APPROX_QUANTILES(disc_impressions_per_day, 2)[OFFSET(1)], 1) AS median_disc_impressions_per_day,
    ROUND(APPROX_QUANTILES(clicks_per_day,           2)[OFFSET(1)], 1) AS median_clicks_per_day,
    ROUND(APPROX_QUANTILES(sessions_per_day,         2)[OFFSET(1)], 1) AS median_sessions_per_day,
    ROUND(APPROX_QUANTILES(units_sold_per_day,       2)[OFFSET(1)], 3) AS median_units_sold_per_day,
    ROUND(APPROX_QUANTILES(bv_per_day,               2)[OFFSET(1)], 2) AS median_bv_per_day,

    -- Conversion metrics
    ROUND(AVG(conv_rate),              6) AS mean_conv_rate,
    ROUND(AVG(conv_rate_new),          6) AS mean_conv_rate_new,
    ROUND(AVG(conv_rate_returning),    6) AS mean_conv_rate_returning,
    ROUND(AVG(pct_sessions_returning), 1) AS mean_pct_sessions_returning,
    ROUND(AVG(pct_returning),          1) AS mean_pct_units_returning,
    ROUND(AVG(bv_per_total_imp),       4) AS mean_bv_per_total_imp,
    ROUND(AVG(bv_per_disc_imp),        4) AS mean_bv_per_disc_imp,

    -- Seasonality: months in which this format ran
    STRING_AGG(
      DISTINCT FORMAT_DATE('%b %Y', promo_start_date)
      ORDER BY FORMAT_DATE('%b %Y', promo_start_date)
    ) AS months_covered
  FROM promo_summary
  GROUP BY promo_format
)

-- =============================================================================
-- OUTPUTS — uncomment the SELECT you want to run
-- =============================================================================

-- 1. Base daily metrics (one row per day, promo + non-promo)
SELECT * FROM promo_daily_metrics ORDER BY date

-- 2. Per-promo summary (totals + per-day averages + conversion metrics)
-- SELECT * FROM promo_summary ORDER BY promo_start_date

-- 3. Decay curve (one row per promo × day number — plot day-by-day trends)
-- SELECT * FROM promo_decay_curve ORDER BY promotion_name, promo_day_number

-- 4. Format summary (mean/median per format, normalized per day)
-- SELECT * FROM promo_format_summary ORDER BY promo_format

-- 5. Monthly baseline (non-promo day averages, for computing lift)
-- SELECT * FROM promo_baseline ORDER BY month
