"""
Artist fame scoring via Google Search (SerpAPI).
For each artist, queries: "artist name" artist
Extracts: total_results, has_knowledge_panel, wikipedia_in_top5, art_platform_in_top5

Run: python artist_fame_scraper.py
Resumes automatically if interrupted (checkpoints after each batch).
"""

import csv
import json
import os
import sys
import time
import requests

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

API_KEY = "0f835524c81b4899d5b5553d7f97a1ee2a4806cdd8e8aa6661fb576d011ec132"
INPUT_FILE = "artist_name.csv"
OUTPUT_FILE = "artist_fame_results.csv"
CHECKPOINT_FILE = "artist_fame_checkpoint.json"

# Domains that indicate art-world presence
ART_PLATFORMS = {"artsy.net", "mutualart.com", "sothebys.com", "christies.com",
                 "phillips.com", "bonhams.com", "invaluable.com", "artnet.com",
                 "saatchiart.com", "singulart.com"}

RATE_LIMIT_DELAY = 0.2  # seconds between requests → ~5 req/sec (~5h for 90k artists)


def load_checkpoint():
    if os.path.exists(CHECKPOINT_FILE):
        with open(CHECKPOINT_FILE, "r") as f:
            return json.load(f)
    return {"done": []}


def save_checkpoint(done_names):
    with open(CHECKPOINT_FILE, "w") as f:
        json.dump({"done": done_names}, f)


def query_serpapi(artist_name):
    query = f'"{artist_name}" artist'
    params = {
        "engine": "google",
        "q": query,
        "api_key": API_KEY,
        "num": 5,
        "gl": "us",
        "hl": "en",
    }
    resp = requests.get("https://serpapi.com/search", params=params, timeout=15)
    resp.raise_for_status()
    return resp.json()


def extract_signals(data):
    # Total results count
    search_info = data.get("search_information", {})
    total_results = search_info.get("total_results", 0)

    # Knowledge panel (Google entity card)
    has_knowledge_panel = "knowledge_graph" in data

    # Scan top 5 organic results
    organic = data.get("organic_results", [])[:5]
    urls = [r.get("link", "") for r in organic]

    wikipedia_in_top5 = any("wikipedia.org" in u for u in urls)
    art_platform_in_top5 = any(
        any(platform in u for platform in ART_PLATFORMS)
        for u in urls
    )
    instagram_in_top5 = any("instagram.com" in u for u in urls)

    return {
        "total_results": total_results,
        "has_knowledge_panel": has_knowledge_panel,
        "wikipedia_in_top5": wikipedia_in_top5,
        "art_platform_in_top5": art_platform_in_top5,
        "instagram_in_top5": instagram_in_top5,
    }


def load_artists():
    with open(INPUT_FILE, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        return [
            {"artist_id": row.get("artist_id", ""), "artist_name": row["artist_name"].strip()}
            for row in reader if row["artist_name"].strip()
        ]


def append_result(row):
    file_exists = os.path.exists(OUTPUT_FILE)
    with open(OUTPUT_FILE, "a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["artist_id", "artist_name", "total_results",
                                               "has_knowledge_panel", "wikipedia_in_top5",
                                               "art_platform_in_top5", "instagram_in_top5", "error"])
        if not file_exists:
            writer.writeheader()
        writer.writerow(row)


def main():
    artists = load_artists()
    checkpoint = load_checkpoint()
    done_set = set(checkpoint["done"])

    remaining = [a for a in artists if a["artist_name"] not in done_set]
    total = len(artists)
    done_count = len(done_set)

    print(f"Total artists: {total} | Already done: {done_count} | Remaining: {len(remaining)}")
    print(f"Estimated time: {len(remaining) * RATE_LIMIT_DELAY / 60:.1f} minutes\n")

    for i, artist in enumerate(remaining, start=done_count + 1):
        name = artist["artist_name"]
        artist_id = artist["artist_id"]
        print(f"[{i}/{total}] {name} ... ", end="", flush=True)
        try:
            data = query_serpapi(name)
            signals = extract_signals(data)
            row = {"artist_id": artist_id, "artist_name": name, **signals, "error": ""}
            print(f"{signals['total_results']:,} results | "
                  f"KP={signals['has_knowledge_panel']} | "
                  f"Wiki={signals['wikipedia_in_top5']} | "
                  f"IG={signals['instagram_in_top5']}")
        except Exception as e:
            row = {"artist_id": artist_id, "artist_name": name, "total_results": None,
                   "has_knowledge_panel": None, "wikipedia_in_top5": None,
                   "art_platform_in_top5": None, "instagram_in_top5": None, "error": str(e)}
            print(f"ERROR: {e}")

        append_result(row)
        done_set.add(name)
        save_checkpoint(list(done_set))
        time.sleep(RATE_LIMIT_DELAY)

    print(f"\nDone. Results saved to {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
