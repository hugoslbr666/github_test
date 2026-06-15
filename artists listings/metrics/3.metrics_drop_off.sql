WITH
-- First sale date per artwork (in case of multiple sales)
first_sales AS (
  SELECT artwork_id, MIN(paid_at) AS paid_at
  FROM `singulart-data.connected_sheets.all_sales`
  GROUP BY artwork_id
),

-- Cohort: artworks from L36M that are currently online OR have sold
-- Excludes artworks that were de-listed without selling (we don't know their censoring date)
artwork_cohort AS (
  SELECT
    aa.artwork_id,
    DATE(aa.artwork_online_at)                                   AS online_date,
    DATE(fs.paid_at)                                             AS paid_date,
    DATE_DIFF(DATE(fs.paid_at), DATE(aa.artwork_online_at), DAY) AS days_to_sale,
    DATE_DIFF(CURRENT_DATE, DATE(aa.artwork_online_at), DAY)      AS days_online_today
  FROM `singulart-data.connected_sheets.all_artworks` aa
  LEFT JOIN first_sales fs ON fs.artwork_id = aa.artwork_id
  WHERE aa.artwork_online_at IS NOT NULL
    AND DATE(aa.artwork_online_at) >= DATE_SUB(CURRENT_DATE, INTERVAL 36 MONTH)
    AND (aa.is_hiearchically_online = 1 OR fs.paid_at IS NOT NULL)
    -- exclude same-day sales (listing + purchase on the same day, likely B2B)
    AND (fs.paid_at IS NULL OR DATE_DIFF(DATE(fs.paid_at), DATE(aa.artwork_online_at), DAY) > 0)
),

total_sold AS (
  SELECT COUNT(*) AS nb
  FROM artwork_cohort
  WHERE paid_date IS NOT NULL
),

brackets AS (
  SELECT '1. Day 000-030' AS label,   0 AS day_start,   30 AS day_end UNION ALL
  SELECT '2. Day 031-060',            31,    60 UNION ALL
  SELECT '3. Day 061-090',            61,    90 UNION ALL
  SELECT '4. Day 091-180',            91,   180 UNION ALL
  SELECT '5. Day 181-365',           181,   365 UNION ALL
  SELECT '6. Day 366-730',           366,   730 UNION ALL
  SELECT '7. Day 730+',              731, 99999
)

SELECT
  b.label                                                               AS age_bracket,

  -- Artworks that entered this bracket alive (survived to day_start without selling)
  -- An artwork is "at risk" if: sold at or after day_start, OR still online with day_start days elapsed
  COUNTIF(
    ac.days_to_sale >= b.day_start
    OR (ac.paid_date IS NULL AND ac.days_online_today >= b.day_start)
  )                                                                     AS at_risk,

  -- Artworks that sold during this bracket
  COUNTIF(ac.days_to_sale BETWEEN b.day_start AND b.day_end)           AS sold_in_bracket,

  -- Hazard rate: given you've survived to this bracket, what's your chance of selling in it?
  -- This is the core metric — the drop-off is where this falls sharply
  ROUND(
    COUNTIF(ac.days_to_sale BETWEEN b.day_start AND b.day_end)
    / NULLIF(COUNTIF(
        ac.days_to_sale >= b.day_start
        OR (ac.paid_date IS NULL AND ac.days_online_today >= b.day_start)
      ), 0),
    4
  )                                                                     AS hazard_rate,

  -- Survival rate = 1 - hazard: the % that make it through the bracket without selling
  ROUND(
    1 - COUNTIF(ac.days_to_sale BETWEEN b.day_start AND b.day_end)
    / NULLIF(COUNTIF(
        ac.days_to_sale >= b.day_start
        OR (ac.paid_date IS NULL AND ac.days_online_today >= b.day_start)
      ), 0),
    4
  )                                                                     AS survival_rate,

  -- Distribution of sale timing: of all artworks that ever sold, what % sold in this bracket?
  ROUND(
    COUNTIF(ac.days_to_sale BETWEEN b.day_start AND b.day_end)
    / (SELECT nb FROM total_sold),
    4
  )                                                                     AS pct_of_all_sold

FROM artwork_cohort ac
CROSS JOIN brackets b
GROUP BY b.label, b.day_start, b.day_end
ORDER BY b.day_start
