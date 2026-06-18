"""
Artist fame scoring via Google Search (SerpAPI).
For each artist, queries: "artist name" artist
Extracts: total_results, has_knowledge_panel, wikipedia_in_top5, art_platform_in_top5, instagram_in_top5

Run: python artist_fame_scraper.py
Resumes automatically if interrupted (checkpoints every 50 completions).
"""

import csv
import json
import os
import sys
import threading
import time
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

API_KEY = "0f835524c81b4899d5b5553d7f97a1ee2a4806cdd8e8aa6661fb576d011ec132"
INPUT_FILE = "artist_name.csv"
OUTPUT_FILE = "artist_fame_results.csv"
CHECKPOINT_FILE = "artist_fame_checkpoint.json"
WORKERS = 10           # parallel threads
CHECKPOINT_EVERY = 50  # save checkpoint every N completions

ART_PLATFORMS = {"artsy.net", "mutualart.com", "sothebys.com", "christies.com",
                 "phillips.com", "bonhams.com", "invaluable.com", "artnet.com",
                 "saatchiart.com", "singulart.com"}

file_lock = threading.Lock()
checkpoint_lock = threading.Lock()
print_lock = threading.Lock()
counter_lock = threading.Lock()

done_set = set()
completed_count = 0


def load_checkpoint():
    if os.path.exists(CHECKPOINT_FILE):
        with open(CHECKPOINT_FILE, "r") as f:
            return set(json.load(f).get("done", []))
    return set()


def save_checkpoint():
    with checkpoint_lock:
        with open(CHECKPOINT_FILE, "w") as f:
            json.dump({"done": list(done_set)}, f)


def query_serpapi(artist_name):
    params = {
        "engine": "google",
        "q": f'"{artist_name}" artist',
        "api_key": API_KEY,
        "num": 5,
        "gl": "us",
        "hl": "en",
    }
    resp = requests.get("https://serpapi.com/search", params=params, timeout=15)
    resp.raise_for_status()
    return resp.json()


def extract_signals(data):
    search_info = data.get("search_information", {})
    total_results = search_info.get("total_results", 0)
    has_knowledge_panel = "knowledge_graph" in data

    urls = [r.get("link", "") for r in data.get("organic_results", [])[:5]]
    wikipedia_in_top5 = any("wikipedia.org" in u for u in urls)
    art_platform_in_top5 = any(any(p in u for p in ART_PLATFORMS) for u in urls)
    instagram_in_top5 = any("instagram.com" in u for u in urls)

    return {
        "total_results": total_results,
        "has_knowledge_panel": has_knowledge_panel,
        "wikipedia_in_top5": wikipedia_in_top5,
        "art_platform_in_top5": art_platform_in_top5,
        "instagram_in_top5": instagram_in_top5,
    }


def append_result(row):
    with file_lock:
        file_exists = os.path.exists(OUTPUT_FILE)
        with open(OUTPUT_FILE, "a", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=["artist_id", "artist_name", "total_results",
                                                   "has_knowledge_panel", "wikipedia_in_top5",
                                                   "art_platform_in_top5", "instagram_in_top5", "error"])
            if not file_exists:
                writer.writeheader()
            writer.writerow(row)


def load_artists():
    with open(INPUT_FILE, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        return [
            {"artist_id": row.get("artist_id", ""), "artist_name": row["artist_name"].strip()}
            for row in reader if row["artist_name"].strip()
        ]


def process_artist(artist, index, total):
    global completed_count

    name = artist["artist_name"]
    artist_id = artist["artist_id"]
    try:
        data = query_serpapi(name)
        signals = extract_signals(data)
        row = {"artist_id": artist_id, "artist_name": name, **signals, "error": ""}
        msg = (f"[{index}/{total}] {name} — "
               f"{signals['total_results']:,} results | "
               f"KP={signals['has_knowledge_panel']} | "
               f"Wiki={signals['wikipedia_in_top5']} | "
               f"IG={signals['instagram_in_top5']}")
    except Exception as e:
        row = {"artist_id": artist_id, "artist_name": name, "total_results": None,
               "has_knowledge_panel": None, "wikipedia_in_top5": None,
               "art_platform_in_top5": None, "instagram_in_top5": None, "error": str(e)}
        msg = f"[{index}/{total}] {name} — ERROR: {e}"

    append_result(row)

    with counter_lock:
        done_set.add(name)
        completed_count += 1
        should_checkpoint = completed_count % CHECKPOINT_EVERY == 0

    if should_checkpoint:
        save_checkpoint()

    with print_lock:
        print(msg, flush=True)


def main():
    global done_set

    artists = load_artists()
    done_set = load_checkpoint()

    remaining = [a for a in artists if a["artist_name"] not in done_set]
    total = len(artists)
    already_done = len(done_set)

    print(f"Total artists: {total} | Already done: {already_done} | Remaining: {len(remaining)}")
    est_minutes = len(remaining) / WORKERS / 2  # ~2 req/sec per thread (network latency)
    print(f"Workers: {WORKERS} | Estimated time: {est_minutes:.0f} minutes\n")

    with ThreadPoolExecutor(max_workers=WORKERS) as executor:
        futures = {
            executor.submit(process_artist, artist, already_done + i + 1, total): artist
            for i, artist in enumerate(remaining)
        }
        try:
            for future in as_completed(futures):
                future.result()
        except KeyboardInterrupt:
            print("\nInterrupted — saving checkpoint...")
            executor.shutdown(wait=False, cancel_futures=True)

    save_checkpoint()
    print(f"\nDone. Results saved to {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
