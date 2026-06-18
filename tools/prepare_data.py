#!/usr/bin/env python3
"""Prepare local province/city CIDR data for the po0 whitelist script."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import time
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INDEX = ROOT / "data" / "cncity.md"
REGIONS_DIR = ROOT / "data" / "regions"
REGIONS_JSON = ROOT / "data" / "regions.json"
VENDOR_DIR = ROOT / "vendor"

ROW_RE = re.compile(r"^\|([^|]+)\|([^|]+)\|$")
CODE_RE = re.compile(r"/(\d{6})\.txt$")
EXCLUDED_PROVINCE_CODES = {"710000", "810000", "820000"}


def parse_cncity(markdown: str) -> list[dict[str, object]]:
    provinces: list[dict[str, object]] = []
    current: dict[str, object] | None = None

    for raw_line in markdown.splitlines():
        line = raw_line.strip()
        if not line or line == "|---|---|":
            continue

        match = ROW_RE.match(line)
        if not match:
            continue

        name, url = match.group(1).strip(), match.group(2).strip()
        code_match = CODE_RE.search(url)
        if not code_match:
            continue

        code = code_match.group(1)
        entry = {"name": name, "code": code, "file": f"regions/{code}.txt", "url": url}

        if code.endswith("0000"):
            if code == "100000" or code in EXCLUDED_PROVINCE_CODES:
                current = None
                continue
            current = {**entry, "cities": []}
            provinces.append(current)
        elif current is not None:
            current["cities"].append(entry)  # type: ignore[index]

    return provinces


def download_text(url: str) -> str:
    last_error: Exception | None = None
    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return response.read().decode("utf-8")
        except Exception as exc:  # pragma: no cover - network failure path
            last_error = exc
            time.sleep(attempt)
    raise RuntimeError(f"failed to download {url}: {last_error}")


def write_region_file(code: str, url: str) -> None:
    REGIONS_DIR.mkdir(parents=True, exist_ok=True)
    target = REGIONS_DIR / f"{code}.txt"
    if target.exists() and target.stat().st_size > 0:
        return
    text = download_text(url)
    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.startswith("#")]
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")


def iter_entries(provinces: list[dict[str, object]]):
    for province in provinces:
        yield province
        for city in province["cities"]:  # type: ignore[index]
            yield city


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, default=DEFAULT_INDEX, help="Local cncity.md path")
    parser.add_argument("--ipdb", type=Path, help="Optional local ipipfree.ipdb path to bundle")
    parser.add_argument("--skip-download", action="store_true", help="Only generate regions.json")
    args = parser.parse_args()

    markdown = args.index.read_text(encoding="utf-8")
    provinces = parse_cncity(markdown)
    if not provinces:
        raise SystemExit("No provinces parsed from cncity index")

    if not args.skip_download:
        entries = list(iter_entries(provinces))
        for index, entry in enumerate(entries, 1):
            print(f"[{index}/{len(entries)}] {entry['code']} {entry['name']}")
            write_region_file(str(entry["code"]), str(entry["url"]))

    metadata = {
        "source": "https://github.com/metowolf/iplist/blob/master/docs/cncity.md",
        "generated_by": "tools/prepare_data.py",
        "provinces": provinces,
    }
    REGIONS_JSON.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if args.ipdb:
        if not args.ipdb.exists():
            raise SystemExit(f"ipdb file not found: {args.ipdb}")
        VENDOR_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.ipdb, VENDOR_DIR / "ipipfree.ipdb")

    print(f"Wrote {REGIONS_JSON}")
    print(f"Province count: {len(provinces)}")
    print(f"Indexed region files: {sum(1 for _ in iter_entries(provinces))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
