#!/usr/bin/env python3
"""
Artwork Sales Alignment Scorer
================================
Builds a visual/thematic sales profile per artist from historical_sale_data.csv,
then scores every artwork in all_artworks.csv against that profile and assigns
it to one of 5 clusters:

    Cluster 1: 80–100 %  (best match)
    Cluster 2: 60–79  %
    Cluster 3: 40–59  %
    Cluster 4: 20–39  %
    Cluster 5:  0–19  %  (worst match)

Scoring dimensions (weights sum to 1):
    categories   30 %  – do the artwork's categories appear in sold work?
    styles       30 %  – do the artwork's styles appear in sold work?
    medium       15 %  – does the medium match what sells?
    price        15 %  – is the price near the typical selling price?
    orientation  10 %  – does the orientation match what sells?

Each dimension is normalised so that the *most typical* value in the
sales data scores 1.0; less common values score proportionally lower;
values that never appeared in sales score 0.0.
"""

import os
import sys
from collections import Counter

import numpy as np
import pandas as pd

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

WEIGHTS = {
    "category":    0.30,
    "style":       0.30,
    "medium":      0.15,
    "price":       0.15,
    "orientation": 0.10,
}

# Lower bound of each cluster (cluster 1 = ≥80, …, cluster 5 = <20)
CLUSTER_THRESHOLDS = [80, 60, 40, 20]

SALES_PATH     = "historical_sale_data.csv"
INVENTORY_PATH = "all_artworks.csv"
OUTPUT_PATH    = "artwork_clusters.csv"


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def parse_tags(value) -> list[str]:
    """Return a list of stripped tags from a comma-separated (possibly quoted) cell."""
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return []
    return [t.strip().strip('"') for t in str(value).strip('"').split(",") if t.strip()]


def build_profile(sales: pd.DataFrame) -> dict:
    """
    Compute a normalised frequency profile from a set of sold artworks.

    Each tag frequency is divided by the highest frequency in its group,
    so the most common sold value always maps to 1.0 and every other value
    maps to a proportional score in (0, 1].
    """
    n = len(sales)
    cat_c   = Counter()
    style_c = Counter()
    med_c   = Counter()
    ori_c   = Counter()
    prices  = []

    for _, row in sales.iterrows():
        for tag in parse_tags(row.get("categories")):
            cat_c[tag] += 1
        for tag in parse_tags(row.get("styles")):
            style_c[tag] += 1
        if pd.notna(row.get("medium")):
            med_c[str(row["medium"])] += 1
        if pd.notna(row.get("orientation")):
            ori_c[str(row["orientation"])] += 1
        if pd.notna(row.get("price_eur")):
            prices.append(float(row["price_eur"]))

    def normalise(counter: Counter) -> dict[str, float]:
        if not counter:
            return {}
        max_freq = max(counter.values()) / n
        return {k: (v / n) / max_freq for k, v in counter.items()}

    prices_arr = np.array(prices) if prices else np.array([0.0])
    price_stats = {
        "mean": float(np.mean(prices_arr)),
        "std":  max(float(np.std(prices_arr)), 1.0),   # guard against zero std
    }

    return {
        "cat_freq":   normalise(cat_c),
        "style_freq": normalise(style_c),
        "med_freq":   normalise(med_c),
        "ori_freq":   normalise(ori_c),
        "price":      price_stats,
        "n_sales":    n,
    }


def score_artwork(row: pd.Series, profile: dict) -> tuple[dict, float]:
    """
    Return (component_scores, total_pct) where total_pct ∈ [0, 100].

    Each component score is in [0, 1].  For multi-value fields (categories,
    styles) the score is the average normalised frequency across all tags on
    the artwork; unknown tags contribute 0.
    """
    # Categories
    cats = parse_tags(row.get("categories"))
    cat_score = float(np.mean([profile["cat_freq"].get(c, 0.0) for c in cats])) if cats else 0.0

    # Styles
    styles = parse_tags(row.get("styles"))
    sty_score = float(np.mean([profile["style_freq"].get(s, 0.0) for s in styles])) if styles else 0.0

    # Medium (single value)
    medium = str(row.get("medium", "")) if pd.notna(row.get("medium")) else ""
    med_score = profile["med_freq"].get(medium, 0.0)

    # Orientation (single value)
    orient = str(row.get("orientation", "")) if pd.notna(row.get("orientation")) else ""
    ori_score = profile["ori_freq"].get(orient, 0.0)

    # Price – Gaussian kernel centred on the mean selling price
    price_val = row.get("price_eur")
    if pd.notna(price_val):
        z = (float(price_val) - profile["price"]["mean"]) / profile["price"]["std"]
        pri_score = float(np.exp(-0.5 * z ** 2))
    else:
        pri_score = 0.5   # neutral when price is unknown

    components = {
        "category":    cat_score,
        "style":       sty_score,
        "medium":      med_score,
        "price":       pri_score,
        "orientation": ori_score,
    }

    total_pct = sum(WEIGHTS[k] * components[k] for k in WEIGHTS) * 100.0
    return components, round(total_pct, 1)


def assign_cluster(score_pct: float) -> int:
    for i, threshold in enumerate(CLUSTER_THRESHOLDS):
        if score_pct >= threshold:
            return i + 1
    return 5


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    # ── Load data ──────────────────────────────────────────────────────────
    for path in (SALES_PATH, INVENTORY_PATH):
        if not os.path.exists(path):
            sys.exit(
                f"\nERROR: '{path}' not found.\n"
                + (
                    "Please export the all_artworks.sql query from BigQuery "
                    "and save it as all_artworks.csv in this folder."
                    if path == INVENTORY_PATH
                    else ""
                )
            )

    sales_df     = pd.read_csv(SALES_PATH, sep="\t")
    inventory_df = pd.read_csv(INVENTORY_PATH)

    print(f"Sales records : {len(sales_df):,}")
    print(f"Inventory rows: {len(inventory_df):,}")

    # ── Build per-artist sales profiles ────────────────────────────────────
    print("\nBuilding sales profiles...")
    profiles: dict[int, dict] = {}
    for artist_id, group in sales_df.groupby("artist_id"):
        profiles[artist_id] = build_profile(group)
        artist_name = group["artist"].iloc[0]
        p = profiles[artist_id]
        top_cat   = max(p["cat_freq"],   key=p["cat_freq"].get,   default="–")
        top_style = max(p["style_freq"], key=p["style_freq"].get, default="–")
        top_med   = max(p["med_freq"],   key=p["med_freq"].get,   default="–")
        top_ori   = max(p["ori_freq"],   key=p["ori_freq"].get,   default="–")
        print(
            f"  {artist_name} ({p['n_sales']} sales) | "
            f"top category={top_cat}, style={top_style}, "
            f"medium={top_med}, orientation={top_ori}, "
            f"avg_price={p['price']['mean']:.0f}€"
        )

    # ── Score every inventory artwork ───────────────────────────────────────
    print("\nScoring inventory...")
    rows = []
    skipped = 0
    for _, row in inventory_df.iterrows():
        artist_id = row["artist_id"]
        if artist_id not in profiles:
            skipped += 1
            continue

        components, total_pct = score_artwork(row, profiles[artist_id])
        cluster = assign_cluster(total_pct)

        rows.append({
            "artist_id":         row["artist_id"],
            "artist":            row["artist"],
            "artwork_id":        row["artwork_id"],
            "categories":        row.get("categories", ""),
            "styles":            row.get("styles", ""),
            "medium":            row.get("medium", ""),
            "price_eur":         row.get("price_eur", ""),
            "orientation":       row.get("orientation", ""),
            "match_score":       total_pct,
            "cluster":           cluster,
            "score_category":    round(components["category"]    * 100, 1),
            "score_style":       round(components["style"]       * 100, 1),
            "score_medium":      round(components["medium"]      * 100, 1),
            "score_price":       round(components["price"]       * 100, 1),
            "score_orientation": round(components["orientation"] * 100, 1),
        })

    if skipped:
        print(f"  Skipped {skipped} artworks with no matching sales profile.")

    # ── Save & summarise ───────────────────────────────────────────────────
    results_df = pd.DataFrame(rows)
    results_df.sort_values(
        ["artist_id", "cluster", "match_score"],
        ascending=[True, True, False],
        inplace=True,
    )
    results_df.to_csv(OUTPUT_PATH, index=False)
    print(f"\nResults saved: {OUTPUT_PATH}")

    # Cluster distribution
    print("\n-- Cluster distribution (# artworks) ----------------------------")
    dist = (
        results_df.groupby(["artist", "cluster"])
        .size()
        .unstack(fill_value=0)
        .rename(columns=lambda c: f"C{c}")
    )
    print(dist.to_string())

    # Score summary
    print("\n-- Match score summary per artist --------------------------------")
    summary = results_df.groupby("artist")["match_score"].describe().round(1)
    print(summary[["count", "mean", "std", "min", "25%", "50%", "75%", "max"]].to_string())

    # Per-artist top & bottom examples
    print("\n-- Top 3 best-matching artworks per artist -----------------------")
    for artist, grp in results_df.groupby("artist"):
        top = grp.nlargest(3, "match_score")[
            ["artwork_id", "categories", "styles", "match_score", "cluster"]
        ]
        print(f"\n{artist}")
        print(top.to_string(index=False))

    print("\n-- Top 3 worst-matching artworks per artist ----------------------")
    for artist, grp in results_df.groupby("artist"):
        bot = grp.nsmallest(3, "match_score")[
            ["artwork_id", "categories", "styles", "match_score", "cluster"]
        ]
        print(f"\n{artist}")
        print(bot.to_string(index=False))


if __name__ == "__main__":
    main()
