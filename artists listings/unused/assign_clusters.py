#!/usr/bin/env python3
"""
Assign Sales-Alignment Clusters to Full Artist Catalog
=======================================================
Reads historical_sale_data.csv and all_artworks.csv, builds a per-artist
sales profile, then writes catalog_clusters.csv — one row per artwork with
its cluster assignment (1 = best match, 5 = worst match).

Output columns:
    artist_id, artist, artwork_id, categories, styles, medium,
    price_eur, orientation, match_score, cluster
"""

import os
import sys
from collections import Counter

import numpy as np
import pandas as pd

# ── Configuration ─────────────────────────────────────────────────────────────

WEIGHTS = {
    "category":    0.30,
    "style":       0.30,
    "medium":      0.15,
    "price":       0.15,
    "orientation": 0.10,
}

CLUSTER_THRESHOLDS = [80, 60, 40, 20]   # cluster 1 >= 80, ..., cluster 5 < 20

SALES_PATH     = "historical_sale_data.csv"
INVENTORY_PATH = "all_artworks.csv"
OUTPUT_PATH    = "catalog_clusters.csv"


# ── Helpers ───────────────────────────────────────────────────────────────────

def parse_tags(value) -> list[str]:
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return []
    return [t.strip().strip('"') for t in str(value).strip('"').split(",") if t.strip()]


def build_profile(sales: pd.DataFrame) -> dict:
    """
    Build a normalised frequency profile from sold artworks.
    The most-common value in each dimension scores 1.0; others score
    proportionally. Price is summarised as mean + std for a Gaussian kernel.
    """
    n = len(sales)
    cat_c, style_c, med_c, ori_c = Counter(), Counter(), Counter(), Counter()
    prices = []

    for _, row in sales.iterrows():
        for t in parse_tags(row.get("categories")):
            cat_c[t] += 1
        for t in parse_tags(row.get("styles")):
            style_c[t] += 1
        if pd.notna(row.get("medium")):
            med_c[str(row["medium"])] += 1
        if pd.notna(row.get("orientation")):
            ori_c[str(row["orientation"])] += 1
        if pd.notna(row.get("price_eur")):
            prices.append(float(row["price_eur"]))

    def norm(counter: Counter) -> dict[str, float]:
        if not counter:
            return {}
        peak = max(counter.values()) / n
        return {k: (v / n) / peak for k, v in counter.items()}

    arr = np.array(prices) if prices else np.array([0.0])
    return {
        "cat_freq":   norm(cat_c),
        "style_freq": norm(style_c),
        "med_freq":   norm(med_c),
        "ori_freq":   norm(ori_c),
        "price_mean": float(np.mean(arr)),
        "price_std":  max(float(np.std(arr)), 1.0),
    }


def score(row: pd.Series, profile: dict) -> float:
    """Return a match score in [0, 100]."""
    cats   = parse_tags(row.get("categories"))
    styles = parse_tags(row.get("styles"))
    medium = str(row.get("medium", "")) if pd.notna(row.get("medium")) else ""
    orient = str(row.get("orientation", "")) if pd.notna(row.get("orientation")) else ""

    cat_s   = float(np.mean([profile["cat_freq"].get(c, 0.0)   for c in cats]))   if cats   else 0.0
    style_s = float(np.mean([profile["style_freq"].get(s, 0.0) for s in styles])) if styles else 0.0
    med_s   = profile["med_freq"].get(medium, 0.0)
    ori_s   = profile["ori_freq"].get(orient, 0.0)

    price_val = row.get("price_eur")
    if pd.notna(price_val):
        z = (float(price_val) - profile["price_mean"]) / profile["price_std"]
        pri_s = float(np.exp(-0.5 * z ** 2))
    else:
        pri_s = 0.5

    return round(
        (WEIGHTS["category"]    * cat_s
         + WEIGHTS["style"]       * style_s
         + WEIGHTS["medium"]      * med_s
         + WEIGHTS["price"]       * pri_s
         + WEIGHTS["orientation"] * ori_s) * 100.0,
        1,
    )


def cluster(score_pct: float) -> int:
    for i, threshold in enumerate(CLUSTER_THRESHOLDS):
        if score_pct >= threshold:
            return i + 1
    return 5


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    for path in (SALES_PATH, INVENTORY_PATH):
        if not os.path.exists(path):
            sys.exit(f"ERROR: '{path}' not found.")

    sales_df     = pd.read_csv(SALES_PATH, sep="\t")
    inventory_df = pd.read_csv(INVENTORY_PATH)

    # Build one sales profile per artist
    profiles = {
        artist_id: build_profile(grp)
        for artist_id, grp in sales_df.groupby("artist_id")
    }

    # Score every inventory artwork
    rows = []
    for _, row in inventory_df.iterrows():
        profile = profiles.get(row["artist_id"])
        if profile is None:
            continue
        s = score(row, profile)
        rows.append({
            "artist_id":   row["artist_id"],
            "artist":      row["artist"],
            "artwork_id":  row["artwork_id"],
            "categories":  row.get("categories", ""),
            "styles":      row.get("styles", ""),
            "medium":      row.get("medium", ""),
            "price_eur":   row.get("price_eur", ""),
            "orientation": row.get("orientation", ""),
            "match_score": s,
            "cluster":     cluster(s),
        })

    out = pd.DataFrame(rows)
    out.sort_values(["artist_id", "cluster", "match_score"],
                    ascending=[True, True, False], inplace=True)
    out.to_csv(OUTPUT_PATH, index=False)

    # Console summary
    print(f"Scored {len(out):,} artworks -> {OUTPUT_PATH}\n")
    dist = (
        out.groupby(["artist", "cluster"])
        .size()
        .unstack(fill_value=0)
        .rename(columns=lambda c: f"C{c}")
    )
    pct = dist.div(dist.sum(axis=1), axis=0).mul(100).round(1)
    print("Cluster distribution (#):")
    print(dist.to_string())
    print("\nCluster distribution (%):")
    print(pct.to_string())


if __name__ == "__main__":
    main()
