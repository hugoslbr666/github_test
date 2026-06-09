WITH products AS (
  SELECT *,
         ROW_NUMBER() OVER(PARTITION BY id ORDER BY batch_timestamp DESC) AS rn
  FROM `singulart-data.stripe.products`
),
undup_products AS (
  SELECT * FROM products WHERE rn = 1
),
prices AS (
  SELECT *,
         ROW_NUMBER() OVER(PARTITION BY id ORDER BY batch_timestamp DESC) AS rn
  FROM `singulart-data.stripe.prices`
),
undup_prices AS (
  SELECT * FROM prices WHERE rn = 1
),
base AS (
  SELECT 
    artist_id, 
    customer_id,
    local_event_timestamp,
    event_type,
    mrr_change,
    CONCAT(name, ' ', recurring_interval) AS plan,
    undup_products.name, 
    recurring_interval,
    ROW_NUMBER() OVER(
      PARTITION BY customer_id 
      ORDER BY 
        local_event_timestamp ASC,
        CASE event_type 
          WHEN 'ACTIVE_END' THEN 0 
          WHEN 'ACTIVE_START' THEN 1 
          ELSE 2 
        END
    ) AS changes_linked_to_customer_id
  FROM `singulart-data.sfa_acquisition.artists_mrr_changes` mrr
  LEFT JOIN undup_products ON undup_products.id = mrr.product_id
  LEFT JOIN undup_prices ON undup_prices.id = mrr.price_id
),
paired_events AS (
  SELECT 
    end_event.customer_id,
    end_event.artist_id,
    end_event.local_event_timestamp,
    end_event.recurring_interval AS old_interval,
    start_event.recurring_interval AS new_interval,
    end_event.mrr_change AS mrr_change_end,
    start_event.mrr_change AS mrr_change_start,
    end_event.plan AS old_plan,
    start_event.plan AS new_plan
  FROM base end_event
  JOIN base start_event
    ON end_event.customer_id = start_event.customer_id
   AND end_event.local_event_timestamp = start_event.local_event_timestamp
   AND end_event.event_type = 'ACTIVE_END'
   AND start_event.event_type = 'ACTIVE_START'
  WHERE end_event.recurring_interval = 'month'
    AND start_event.recurring_interval = 'year'
),
latest_event AS (
  SELECT customer_id,
         event_type
  FROM (
    SELECT customer_id,
           event_type,
           ROW_NUMBER() OVER(
             PARTITION BY customer_id
             ORDER BY local_event_timestamp DESC,
                      CASE event_type
                        WHEN 'ACTIVE_END' THEN 0
                        WHEN 'ACTIVE_START' THEN 1
                        ELSE 2
                      END DESC
           ) AS rn
    FROM base
  )
  WHERE rn = 1
)
SELECT p.*
FROM paired_events p
JOIN latest_event l
  ON p.customer_id = l.customer_id
WHERE l.event_type != 'ACTIVE_END';
