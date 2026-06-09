WITH

sellers AS (
  SELECT DISTINCT artist_id
  FROM `singulart-data.connected_sheets.all_sales`
  WHERE artwork_id IS NOT NULL
),

artists_plans AS (
  SELECT
    ap.stripe_subscription_id,
    ap.artist_id,
    ap.stripe_customer_id,
    ap.level,
    ap.frequency,
    ap.started_at,
    ap.ended_at,
    ap.current_period_start,
    ap.current_period_end,
    ap.created_at,
    ap.updated_at,
    row_number() over(partition by ap.artist_id order by ap.created_at asc) as subscription_asc,
    CASE WHEN s.artist_id IS NOT NULL THEN 'Seller' ELSE 'Non-seller' END AS seller_type
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans` ap
  LEFT JOIN sellers s ON s.artist_id = ap.artist_id
),

ts_grouped_sub_item_events AS (
  SELECT
    local_event_timestamp,
    currency,
    customer_id,
    subscription_id,
    ap.level,
    ap.frequency,
    CASE WHEN ap.subscription_asc = 1 THEN 'New' ELSE 'Winback' END AS artist_type,
    ap.seller_type,
    sum(mrr_change) AS mrr_change
  FROM
    `singulart-data.stripe.subscription_item_change_events`
  LEFT JOIN artists_plans ap ON ap.stripe_subscription_id = subscription_id
  GROUP BY
    1, 2, 3, 4, 5, 6, 7, 8
),
ts_grouped_sub_item_events_with_mrr AS (
  SELECT
    *,
    DATE_TRUNC(DATE(local_event_timestamp), day) AS local_event_date,
    -- Stripe defines an "active subscriber" as a customer with non-zero MRR.
    -- Therefore instead of summing up event_type to get subscription count (and its diff),
    -- We count the amount of revenue on each customer instead and later check its movement from / to zero
    SUM(mrr_change) OVER (
      PARTITION BY customer_id
      ORDER BY local_event_timestamp ASC
    ) AS mrr,
    -- We count the # of times MRR has actually changed, and use nullif to ignore events that do not impact MRR
    -- Otherwise we may confuse between new vs. reactivation
    COUNT(nullif(mrr_change, 0)) OVER (
      PARTITION BY customer_id
      ORDER BY local_event_timestamp ASC
    ) AS mrr_change_count
  FROM
    ts_grouped_sub_item_events
),
ts_grouped_sub_item_events_with_previous_mrr AS (
  SELECT
    *,
    COALESCE(
      LAST_VALUE(mrr IGNORE NULLS) OVER (
        PARTITION BY customer_id
        ORDER BY local_event_timestamp ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ),
      0
    ) AS previous_mrr
  FROM
    ts_grouped_sub_item_events_with_mrr
),
customer_events AS (
  SELECT
    *,
    CASE
      WHEN mrr = 0 AND previous_mrr > 0
      THEN 'ACTIVE_END'
      WHEN mrr > 0 AND previous_mrr = 0 AND mrr_change_count = 1
      THEN 'ACTIVE_START'
      WHEN mrr > 0 AND previous_mrr = 0 AND mrr_change_count > 1
      THEN 'REACTIVATE'
      WHEN mrr > previous_mrr
      THEN 'ACTIVE_UPGRADE'
      WHEN mrr < previous_mrr
      THEN 'ACTIVE_DOWNGRADE'
      ELSE NULL
    END AS cus_event_type
  FROM
    ts_grouped_sub_item_events_with_previous_mrr
),
date_grouped_customer_events AS (
  SELECT
    local_event_date,
    customer_events.currency,
    level,
    artist_type,
    frequency,
    seller_type,
    SUM(mrr_change*cr.rate) AS mrr_change,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_START' THEN mrr_change*cr.rate
        ELSE 0
      END
    ) AS new_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'REACTIVATE' THEN mrr_change*cr.rate
        ELSE 0
      END
    ) AS reactivation_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_UPGRADE' THEN mrr_change*cr.rate
        ELSE 0
      END
    ) AS expansion_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_DOWNGRADE' THEN mrr_change*cr.rate
        ELSE 0
      END
    ) AS contraction_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_END' THEN mrr_change*cr.rate
        ELSE 0
      END
    ) AS churn_mrr
  FROM customer_events
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies` sc ON UPPER(sc.currency) = UPPER(customer_events.currency)
  INNER JOIN `singulart-db-to-bigquery.singulartdb.sgt_currencies_rates` cr ON cr.base_id = sc.id AND cr.target_id = 43
  GROUP BY
    1, 2, 3, 4, 5, 6
),
daily_metrics AS (
  SELECT
    local_event_date AS local_date,
    level,
    artist_type,
    frequency,
    seller_type,
    SUM(SUM(mrr_change)) OVER (PARTITION BY level, artist_type, frequency, seller_type ORDER BY local_event_date ASC) AS mrr,
    SUM(mrr_change) AS mrr_change,
    SUM(new_mrr) AS new_mrr,
    SUM(reactivation_mrr) AS reactivation_mrr,
    SUM(expansion_mrr) AS expansion_mrr,
    SUM(contraction_mrr) AS contraction_mrr,
    SUM(churn_mrr) AS churn_mrr
  FROM
    date_grouped_customer_events
  GROUP BY
    1, 2, 3, 4, 5
),
daily_metrics_with_derived AS (
  SELECT
    *,
    COALESCE(
      LAG(mrr, 30) OVER (PARTITION BY level, artist_type, frequency, seller_type ORDER BY local_date),
      0
    ) AS previous_month_mrr
  FROM
    daily_metrics
),
daily_metrics_with_net AS (
  SELECT
    *,
    SUM(ABS(contraction_mrr + churn_mrr) - (expansion_mrr + reactivation_mrr)) OVER (
      PARTITION BY level, artist_type, frequency, seller_type
      ORDER BY local_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS net_mrr_churn
  FROM
    daily_metrics_with_derived
)
  SELECT
    *
    /*,
    CASE net_mrr_churn
      WHEN 0 THEN 0
      ELSE COALESCE(net_mrr_churn / previous_month_mrr * 100, 0)
    END AS total*/
  FROM
    daily_metrics_with_net
  ORDER BY
    1 DESC
