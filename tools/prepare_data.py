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
DEFAULT_INDEX_URL = "https://raw.githubusercontent.com/metowolf/iplist/master/docs/cncity.md"
DEFAULT_DATA_BASE_URL = "https://raw.githubusercontent.com/metowolf/iplist/master/data/cncity"

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


def normalize_region_text(text: str) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.startswith("#")]
    return "\n".join(lines) + "\n"


def region_url(code: str, original_url: str, data_base_url: str) -> str:
    if data_base_url:
        return f"{data_base_url.rstrip('/')}/{code}.txt"
    return original_url


def write_region_file(code: str, url: str, regions_dir: Path, force: bool, data_base_url: str) -> None:
    regions_dir.mkdir(parents=True, exist_ok=True)
    target = regions_dir / f"{code}.txt"
    if target.exists() and target.stat().st_size > 0 and not force:
        return
    text = download_text(region_url(code, url, data_base_url))
    target.write_text(normalize_region_text(text), encoding="utf-8")


def iter_entries(provinces: list[dict[str, object]]):
    for province in provinces:
        yield province
        for city in province["cities"]:  # type: ignore[index]
            yield city


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, default=DEFAULT_INDEX, help="Local cncity.md path")
    parser.add_argument("--index-url", default=DEFAULT_INDEX_URL, help="Remote cncity.md URL")
    parser.add_argument(
        "--data-base-url",
        default=DEFAULT_DATA_BASE_URL,
        help="Base URL for cncity CIDR files; use an empty value to keep URLs from the index",
    )
    parser.add_argument("--output-dir", type=Path, default=ROOT, help="Project-style output directory")
    parser.add_argument("--refresh-index", action="store_true", help="Download the latest cncity index first")
    parser.add_argument("--force", action="store_true", help="Overwrite existing region files")
    parser.add_argument("--ipdb", type=Path, help="Optional local ipipfree.ipdb path to bundle")
    parser.add_argument("--skip-download", action="store_true", help="Only generate regions.json")
    args = parser.parse_args()

    output_dir = args.output_dir
    data_dir = output_dir / "data"
    regions_dir = data_dir / "regions"
    regions_json = data_dir / "regions.json"
    vendor_dir = output_dir / "vendor"

    if args.refresh_index:
        data_dir.mkdir(parents=True, exist_ok=True)
        markdown = download_text(args.index_url)
        (data_dir / "cncity.md").write_text(markdown, encoding="utf-8")
    else:
        markdown = args.index.read_text(encoding="utf-8")

    provinces = parse_cncity(markdown)
    if not provinces:
        raise SystemExit("No provinces parsed from cncity index")

    if not args.skip_download:
        entries = list(iter_entries(provinces))
        for index, entry in enumerate(entries, 1):
            print(f"[{index}/{len(entries)}] {entry['code']} {entry['name']}")
            write_region_file(
                str(entry["code"]),
                str(entry["url"]),
                regions_dir,
                args.force,
                args.data_base_url,
            )

    metadata = {
        "source": "https://github.com/metowolf/iplist/blob/master/docs/cncity.md",
        "index_url": args.index_url,
        "data_base_url": args.data_base_url,
        "generated_by": "tools/prepare_data.py",
        "provinces": provinces,
    }
    data_dir.mkdir(parents=True, exist_ok=True)
    regions_json.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if args.ipdb:
        if not args.ipdb.exists():
            raise SystemExit(f"ipdb file not found: {args.ipdb}")
        vendor_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.ipdb, vendor_dir / "ipipfree.ipdb")

    print(f"Wrote {regions_json}")
    print(f"Province count: {len(provinces)}")
    print(f"Indexed region files: {sum(1 for _ in iter_entries(provinces))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
