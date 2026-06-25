WITH
-- Latest state of each subscription, linked to artist_id
sgt_artists_plans AS (
  SELECT
    artist_id,
    stripe_subscription_id,
    ROW_NUMBER() OVER (PARTITION BY stripe_subscription_id ORDER BY current_period_start DESC) AS rn
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  WHERE frequency in ('year')
),

subscriptions AS (
  SELECT
    sub.id                                          AS subscription_id,
    sap.artist_id,
    DATE(sub.start_date)                            AS subscription_start,
    DATE(sub.ended_at)                              AS subscription_end,
    DATE(sub.canceled_at)                           AS canceled_at,
    COALESCE(sub.cancellation_details_reason, '')   AS cancellation_reason,
    sub.status,
    ROW_NUMBER() OVER (PARTITION BY sub.id ORDER BY sub.batch_timestamp DESC) AS rn
  FROM `singulart-data.stripe.subscriptions` sub
  INNER JOIN sgt_artists_plans sap ON sap.stripe_subscription_id = sub.id AND sap.rn = 1
),

-- One final snapshot per subscription
latest_sub AS (
  SELECT * EXCEPT (rn)
  FROM subscriptions
  WHERE rn = 1
),

-- Wishlist events linked to their artist via artwork
wishlists AS (
  SELECT
    aw.artist_id,
    DATE(w.wishlist_created_at) AS wishlist_date
  FROM `singulart-data.connected_sheets.all_wishlists` w
  INNER JOIN `singulart-data.connected_sheets.all_artworks` aw USING (artwork_id)
),

-- Follow events from sgt_artists_subscriptions
follows AS (
  SELECT
    artist_id,
    DATE(created_at) AS follow_date
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_subscriptions`
),

-- Core table: one row per subscription enriched with artist online date
base AS (
  SELECT
    ls.artist_id,
    ls.subscription_id,
    ls.subscription_start,
    ls.subscription_end,
    ls.canceled_at,
    ls.cancellation_reason,
    ls.status,
    DATE(aa.online_at) AS online_at,
    CASE WHEN aa.last_sale_at IS NULL THEN 'non seller' ELSE 'seller' END AS seller_tag
  FROM latest_sub ls
  LEFT JOIN `singulart-data.connected_sheets.all_artists` aa ON aa.artist_id = ls.artist_id
),

-- Wishlist counts per subscription, bucketed by months since online_at
wishlist_agg AS (
  SELECT
    b.artist_id,
    b.subscription_id,
    SUM(IF(w.wishlist_date BETWEEN b.online_at AND DATE_ADD(b.online_at, INTERVAL 3  MONTH), 1, 0)) AS nb_wishlists_3m,
    SUM(IF(w.wishlist_date BETWEEN b.online_at AND DATE_ADD(b.online_at, INTERVAL 6  MONTH), 1, 0)) AS nb_wishlists_6m,
    SUM(IF(w.wishlist_date BETWEEN b.online_at AND DATE_ADD(b.online_at, INTERVAL 9  MONTH), 1, 0)) AS nb_wishlists_9m,
    SUM(IF(w.wishlist_date BETWEEN b.online_at AND DATE_ADD(b.online_at, INTERVAL 12 MONTH), 1, 0)) AS nb_wishlists_12m
  FROM base b
  LEFT JOIN wishlists w ON w.artist_id = b.artist_id
  GROUP BY 1, 2
),

-- Follow counts per subscription, bucketed by months since online_at
follow_agg AS (
  SELECT
    b.artist_id,
    b.subscription_id,
    SUM(IF(f.follow_date BETWEEN b.online_at AND DATE_ADD(b.online_at, INTERVAL 3  MONTH), 1, 0)) AS nb_follows_3m,
    SUM(IF(f.follow_date BETWEEN b.online_at AND DATE_ADD(b.online_at, INTERVAL 6  MONTH), 1, 0)) AS nb_follows_6m,
    SUM(IF(f.follow_date BETWEEN b.online_at AND DATE_ADD(b.online_at, INTERVAL 9  MONTH), 1, 0)) AS nb_follows_9m,
    SUM(IF(f.follow_date BETWEEN b.online_at AND DATE_ADD(b.online_at, INTERVAL 12 MONTH), 1, 0)) AS nb_follows_12m
  FROM base b
  LEFT JOIN follows f ON f.artist_id = b.artist_id
  GROUP BY 1, 2
)

SELECT
  b.artist_id,
  b.subscription_id,
  FORMAT_DATE('%Y-%m', b.subscription_start) AS subscription_start_month,
  FORMAT_DATE('%Y-%m', b.subscription_end)   AS subscription_end_month,
  FORMAT_DATE('%Y-%m', b.online_at)          AS online_month,
  FORMAT_DATE('%Y-%m', b.canceled_at)        AS cancellation_month,
  b.seller_tag,

  wa.nb_wishlists_3m,
  wa.nb_wishlists_6m,
  wa.nb_wishlists_9m,
  wa.nb_wishlists_12m,

  fa.nb_follows_3m,
  fa.nb_follows_6m,
  fa.nb_follows_9m,
  fa.nb_follows_12m,

  -- Churned = subscription ended due to payment failure within first year after going online
  CASE
    --WHEN b.status = 'canceled'
     --AND b.cancellation_reason = 'payment_failed'
    WHEN b.subscription_end IS NOT NULL
    AND b.subscription_end <= DATE_ADD(b.subscription_start, INTERVAL 12 MONTH)
    THEN 1 ELSE 0
  END AS churned_within_first_year,

  -- Cancelled = voluntary cancellation within N months after going online
  CASE
    WHEN b.canceled_at IS NOT NULL
     AND b.cancellation_reason != 'payment_failed'
     AND b.canceled_at <= DATE_ADD(b.subscription_start, INTERVAL 3 MONTH)
    THEN 1 ELSE 0
  END AS cancelled_within_3_months,

  CASE
    WHEN b.canceled_at IS NOT NULL
     AND b.cancellation_reason != 'payment_failed'
     AND b.canceled_at <= DATE_ADD(b.subscription_start, INTERVAL 6 MONTH)
    THEN 1 ELSE 0
  END AS cancelled_within_6_months,

  CASE
    WHEN b.canceled_at IS NOT NULL
     AND b.cancellation_reason != 'payment_failed'
     AND b.canceled_at <= DATE_ADD(b.subscription_start, INTERVAL 9 MONTH)
    THEN 1 ELSE 0
  END AS cancelled_within_9_months,

  CASE
    WHEN b.canceled_at IS NOT NULL
     AND b.cancellation_reason != 'payment_failed'
     AND b.canceled_at <= DATE_ADD(b.subscription_start, INTERVAL 12 MONTH)
    THEN 1 ELSE 0
  END AS cancelled_within_first_year

FROM base b
LEFT JOIN wishlist_agg wa ON wa.artist_id = b.artist_id AND wa.subscription_id = b.subscription_id
LEFT JOIN follow_agg   fa ON fa.artist_id = b.artist_id AND fa.subscription_id = b.subscription_id
WHERE subscription_start >= '2024-08-01' and subscription_start <= '2025-06-01'
ORDER BY b.artist_id, b.subscription_start
