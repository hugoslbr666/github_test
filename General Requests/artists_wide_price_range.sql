-- Artists who have sold both below 1,000 € and above 3,000 €
-- HAVING MIN < 1000 AND MAX > 3000 guarantees both thresholds are crossed.

SELECT
  ar.artist_id,
  ar.artist_name,
  STRING_AGG(DISTINCT a.medium ORDER BY a.medium)  AS mediums,
  ROUND(MIN(s.amount_eur_paid), 2)                  AS min_sale_price_eur,
  ROUND(MAX(s.amount_eur_paid), 2)                  AS max_sale_price_eur
FROM `singulart-data.connected_sheets.all_sales`    s
JOIN `singulart-data.connected_sheets.all_artworks` a on a.artist_id = s.artist_id
JOIN `singulart-data.connected_sheets.all_artists`  ar on ar.artist_id = s.artist_id
WHERE s.amount_eur_paid IS NOT NULL and ar.is_grand_artist = 0 
GROUP BY ALL
HAVING
  MIN(s.amount_eur_paid) < 1000
  and MIN(s.amount_eur_paid) > 0
  AND MAX(s.amount_eur_paid) > 3000
LIMIT 30
