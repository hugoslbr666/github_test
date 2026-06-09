WITH ts_grouped_sub_item_events AS (
  SELECT
    local_event_timestamp,
    currency,
    customer_id,
    sum(mrr_change) AS mrr_change
  FROM
    subscription_item_change_events_v2_beta
  GROUP BY
    1, 2, 3
),
ts_grouped_sub_item_events_with_mrr AS (
  SELECT
    *,
    DATE_TRUNC('day', DATE(local_event_timestamp)) AS local_event_date,
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
      LAST_VALUE(mrr) IGNORE nulls OVER (
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
    currency,
    SUM(mrr_change) AS mrr_change,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_START' THEN mrr_change
        ELSE 0
      END
    ) AS new_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'REACTIVATE' THEN mrr_change
        ELSE 0
      END
    ) AS reactivation_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_UPGRADE' THEN mrr_change
        ELSE 0
      END
    ) AS expansion_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_DOWNGRADE' THEN mrr_change
        ELSE 0
      END
    ) AS contraction_mrr,
    SUM(
      CASE
        cus_event_type
        WHEN 'ACTIVE_END' THEN mrr_change
        ELSE 0
      END
    ) AS churn_mrr
  FROM
    customer_events
  GROUP BY
    1, 2
),
-- Prepare the multi dimensional table with all days + currency combinations and conversion rate metadata
-- note that exchange_rates_from_usd contains one row for every date from 2010-01-07 until today
-- which is why we don't need to generate a separate date series for the full table
dates_with_rate_per_usd AS (
  SELECT
    -- We use previous day's closing rates in precomputed metrics
    DATE - INTERVAL '1' DAY AS fx_date,
    CAST(
      JSON_PARSE(buy_currency_exchange_rates) AS MAP(VARCHAR, DOUBLE)
    ) AS rate_per_usd
  FROM
    exchange_rates_from_usd
),
currencies AS (
  SELECT
    DISTINCT(currency)
  FROM
    subscription_item_change_events_v2_beta
),
first_default_currency AS (
  SELECT
    default_currency
  FROM
    accounts
  WHERE
    default_currency IS NOT NULL
  LIMIT
    1
),
dates_x_currencies_with_conversion_rate AS (
  SELECT
    fx_date as local_date,
    currency,
    default_currency,
    1 / rate_per_usd [currency] * rate_per_usd [
      COALESCE(default_currency, 'usd')
    ] AS conversion_rate
  FROM
    dates_with_rate_per_usd
    CROSS JOIN currencies
    CROSS JOIN first_default_currency
  ORDER BY
    1, 2
),
daily_metrics_by_currency AS (
  SELECT
    dpc.local_date,
    dpc.currency,
    dpc.conversion_rate,
    COALESCE(
      SUM(mrr_change) OVER (
        PARTITION by dpc.currency
        ORDER BY
        dpc.local_date ASC
      ),
      0
    ) AS mrr,
    COALESCE(
      ROUND(
        SUM(mrr_change) OVER (
          PARTITION by dpc.currency
          ORDER BY
          dpc.local_date ASC
        ) * dpc.conversion_rate
      ),
      0
    ) AS converted_mrr,
    COALESCE(ROUND(mrr_change * conversion_rate), 0) AS converted_mrr_change,
    COALESCE(ROUND(new_mrr * conversion_rate), 0) AS converted_new_mrr,
    COALESCE(ROUND(reactivation_mrr * conversion_rate), 0) AS converted_reactivation_mrr,
    COALESCE(ROUND(expansion_mrr * conversion_rate), 0) AS converted_expansion_mrr,
    COALESCE(ROUND(contraction_mrr * conversion_rate), 0) AS converted_contraction_mrr,
    COALESCE(ROUND(churn_mrr * conversion_rate), 0) AS converted_churn_mrr,
    COALESCE(dgce.mrr_change, 0) AS mrr_change,
    COALESCE(dgce.new_mrr, 0) AS new_mrr,
    COALESCE(dgce.reactivation_mrr, 0) AS reactivation_mrr,
    COALESCE(dgce.expansion_mrr, 0) AS expansion_mrr,
    COALESCE(dgce.contraction_mrr, 0) AS contraction_mrr,
    COALESCE(dgce.churn_mrr, 0) AS churn_mrr
  FROM
    dates_x_currencies_with_conversion_rate dpc
  LEFT JOIN
    date_grouped_customer_events dgce
      ON dpc.local_date = dgce.local_event_date
      AND dpc.currency = dgce.currency
),
daily_metrics AS (
  SELECT
    local_date,
    SUM(converted_mrr) AS mrr,
    SUM(converted_mrr_change) AS mrr_change,
    SUM(converted_new_mrr) AS new_mrr,
    SUM(converted_reactivation_mrr) AS reactivation_mrr,
    SUM(converted_expansion_mrr) AS expansion_mrr,
    SUM(converted_contraction_mrr) AS contraction_mrr,
    SUM(converted_churn_mrr) AS churn_mrr
  FROM
    daily_metrics_by_currency
  GROUP BY
    1
),
daily_metrics_with_derived AS (
  SELECT
    *,
    COALESCE(
      LAG(mrr, 30) OVER (ORDER BY local_date),
      0
    ) AS previous_month_mrr
  FROM
    daily_metrics
),
daily_metrics_with_net AS (
  SELECT
    *,
    SUM(ABS(contraction_mrr + churn_mrr) - (expansion_mrr + reactivation_mrr)) OVER (
      ORDER BY local_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS net_mrr_churn
  FROM
    daily_metrics_with_derived
),
daily_metrics_with_net_rate AS (
  SELECT
    *,
    ROUND(
      CASE net_mrr_churn
        WHEN 0 THEN 0
        ELSE COALESCE(net_mrr_churn / previous_month_mrr * 100, 0)
      END
    ) as total
  FROM
    daily_metrics_with_net
  ORDER BY
    1 DESC
)
SELECT
  DATE_FORMAT(local_date, '%M %e, %Y') AS Date,
  total as Rate
FROM
  daily_metrics_with_net_rate
WHERE
  local_date >= CAST(DATE_FORMAT(CURRENT_DATE, '%Y-%m-%d') AS DATE) - INTERVAL '24' MONTH