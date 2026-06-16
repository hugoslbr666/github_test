-- Average sale price and 80% price range (P10–P90) per medium
-- The 80% range excludes the bottom 10% and top 10% of sold prices.

SELECT
  a.medium,
  COUNT(*)                                                             AS total_sales,
  ROUND(AVG(s.amount_eur_paid), 2)                                    AS avg_sale_price_eur,
  ROUND(APPROX_QUANTILES(s.amount_eur_paid, 10)[OFFSET(1)], 2)       AS p10_sale_price_eur,
  ROUND(APPROX_QUANTILES(s.amount_eur_paid, 10)[OFFSET(9)], 2)       AS p90_sale_price_eur
FROM `singulart-data.connected_sheets.all_sales`    s
JOIN `singulart-data.connected_sheets.all_artworks` a USING (artwork_id)
WHERE a.medium             IS NOT NULL
  AND s.amount_eur_paid    IS NOT NULL
GROUP BY a.medium
ORDER BY total_sales DESC
