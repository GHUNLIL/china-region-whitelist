#!/usr/bin/env python3
"""Build the bundled mainland carrier/CERNET IPv4 access list.

The operator lists are BGP-derived.  Dedicated carrier data-centre ASNs are
identified from their current ASN holder names and subtracted before the
result is intersected with the bundled APNIC CN allocation list.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import ipaddress
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_COUNTRY_FILE = ROOT / "data" / "country" / "CN.txt"
DEFAULT_OUTPUT_FILE = ROOT / "data" / "country" / "CN-ISP.txt"
DEFAULT_AUDIT_FILE = ROOT / "data" / "operator-access" / "excluded-asns.tsv"

OPERATOR_NAMES = ("chinanet", "unicom", "cmcc", "cernet")
CARRIER_ASN_NAMES = ("chinanet", "unicom", "cmcc")
DEFAULT_OPERATOR_BASE_URL = (
    "https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists"
)
DEFAULT_ASN_LIST_BASE_URL = (
    "https://raw.githubusercontent.com/xingpingcn/china-mainland-asn/main/asn_txt"
)
DEFAULT_ASN_PREFIX_BASE_URL = (
    "https://raw.githubusercontent.com/ipverse/as-ip-blocks/master/as"
)
DEFAULT_RIPE_AS_NAMES_URL = "https://stat.ripe.net/data/as-names/data.json"

# Match dedicated hosting networks conservatively by the registered ASN name.
# MAN/backbone/5G/IoT carrier networks remain in the access list.
DATA_CENTER_RE = re.compile(r"IDC|IDCC|DATA[ _-]*CENT(?:ER|RE)|CLOUD", re.IGNORECASE)
ASN_RE = re.compile(r"^[1-9][0-9]{0,9}$")


def download_text(url: str, *, optional: bool = False) -> str:
    last_error: Exception | None = None
    request = urllib.request.Request(url, headers={"User-Agent": "china-region-whitelist"})
    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            if optional and exc.code == 404:
                return ""
            last_error = exc
        except Exception as exc:  # pragma: no cover - network failure path
            last_error = exc
        time.sleep(attempt)
    raise RuntimeError(f"failed to download {url}: {last_error}")


def parse_asn_list(text: str) -> list[int]:
    values: set[int] = set()
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//") or line.startswith("#"):
            continue
        for token in re.split(r"[\s,]+", line):
            if not token:
                continue
            token = token.removeprefix("AS").removeprefix("as")
            if not ASN_RE.fullmatch(token):
                raise ValueError(f"invalid ASN token: {token}")
            asn = int(token)
            if asn > 4294967295:
                raise ValueError(f"ASN out of range: {asn}")
            values.add(asn)
    return sorted(values)


def parse_ipv4_networks(text: str) -> list[ipaddress.IPv4Network]:
    networks: list[ipaddress.IPv4Network] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or ":" in line:
            continue
        network = ipaddress.ip_network(line, strict=False)
        if isinstance(network, ipaddress.IPv4Network):
            networks.append(network)
    return networks


def networks_to_intervals(
    networks: list[ipaddress.IPv4Network],
) -> list[tuple[int, int]]:
    intervals = sorted((int(network.network_address), int(network.broadcast_address)) for network in networks)
    merged: list[tuple[int, int]] = []
    for start, end in intervals:
        if merged and start <= merged[-1][1] + 1:
            previous_start, previous_end = merged[-1]
            merged[-1] = (previous_start, max(previous_end, end))
        else:
            merged.append((start, end))
    return merged


def intersect_intervals(
    left: list[tuple[int, int]], right: list[tuple[int, int]]
) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    left_index = right_index = 0
    while left_index < len(left) and right_index < len(right):
        left_start, left_end = left[left_index]
        right_start, right_end = right[right_index]
        start, end = max(left_start, right_start), min(left_end, right_end)
        if start <= end:
            result.append((start, end))
        if left_end < right_end:
            left_index += 1
        else:
            right_index += 1
    return result


def subtract_intervals(
    allowed: list[tuple[int, int]], denied: list[tuple[int, int]]
) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    denied_index = 0
    for allowed_start, allowed_end in allowed:
        cursor = allowed_start
        while denied_index < len(denied) and denied[denied_index][1] < cursor:
            denied_index += 1
        index = denied_index
        while index < len(denied) and denied[index][0] <= allowed_end:
            denied_start, denied_end = denied[index]
            if denied_start > cursor:
                result.append((cursor, min(allowed_end, denied_start - 1)))
            cursor = max(cursor, denied_end + 1)
            if cursor > allowed_end:
                break
            index += 1
        if cursor <= allowed_end:
            result.append((cursor, allowed_end))
    return result


def intervals_to_networks(intervals: list[tuple[int, int]]) -> list[ipaddress.IPv4Network]:
    networks: list[ipaddress.IPv4Network] = []
    for start, end in intervals:
        networks.extend(
            ipaddress.summarize_address_range(
                ipaddress.IPv4Address(start), ipaddress.IPv4Address(end)
            )
        )
    return networks


def build_access_networks(
    operator_texts: list[str], country_text: str, excluded_prefix_texts: list[str]
) -> list[ipaddress.IPv4Network]:
    operator_networks = [
        network for text in operator_texts for network in parse_ipv4_networks(text)
    ]
    country_networks = parse_ipv4_networks(country_text)
    excluded_networks = [
        network for text in excluded_prefix_texts for network in parse_ipv4_networks(text)
    ]
    if not operator_networks:
        raise RuntimeError("operator sources contain no IPv4 prefixes")
    if not country_networks:
        raise RuntimeError("country source contains no IPv4 prefixes")

    mainland_operator = intersect_intervals(
        networks_to_intervals(operator_networks), networks_to_intervals(country_networks)
    )
    filtered = subtract_intervals(mainland_operator, networks_to_intervals(excluded_networks))
    return intervals_to_networks(filtered)


def fetch_asn_names(asns: list[int], base_url: str) -> dict[int, str]:
    names: dict[int, str] = {}
    for offset in range(0, len(asns), 100):
        chunk = asns[offset : offset + 100]
        query = urllib.parse.urlencode({"resource": ",".join(str(asn) for asn in chunk)})
        payload = json.loads(download_text(f"{base_url}?{query}"))
        raw_names = payload.get("data", {}).get("names", {})
        for asn in chunk:
            names[asn] = str(raw_names.get(str(asn), ""))
    return names


def classify_excluded_asns(
    carrier_asns: dict[str, list[int]], names: dict[int, str]
) -> list[tuple[str, int, str]]:
    excluded: list[tuple[str, int, str]] = []
    for carrier in CARRIER_ASN_NAMES:
        for asn in carrier_asns.get(carrier, []):
            holder = names.get(asn, "")
            if holder and DATA_CENTER_RE.search(holder):
                excluded.append((carrier, asn, holder))
    return excluded


def read_source(name: str, local_dir: Path | None, base_url: str) -> str:
    if local_dir is not None:
        return (local_dir / f"{name}.txt").read_text(encoding="utf-8")
    return download_text(f"{base_url.rstrip('/')}/{name}.txt")


def fetch_excluded_prefixes(
    excluded: list[tuple[str, int, str]], base_url: str
) -> list[str]:
    def fetch(item: tuple[str, int, str]) -> str:
        _carrier, asn, _holder = item
        return download_text(
            f"{base_url.rstrip('/')}/{asn}/ipv4-aggregated.txt", optional=True
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
        return list(executor.map(fetch, excluded))


def render_audit(excluded: list[tuple[str, int, str]]) -> str:
    lines = [
        "# Dedicated carrier IDC/cloud ASNs excluded from CN-ISP.txt.",
        "# Classification uses the current RIPEstat ASN holder name.",
        "carrier\tasn\tholder",
    ]
    lines.extend(f"{carrier}\tAS{asn}\t{holder}" for carrier, asn, holder in excluded)
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--country-file", type=Path, default=DEFAULT_COUNTRY_FILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT_FILE)
    parser.add_argument("--audit", type=Path, default=DEFAULT_AUDIT_FILE)
    parser.add_argument("--operator-dir", type=Path)
    parser.add_argument("--asn-list-dir", type=Path)
    parser.add_argument("--operator-base-url", default=DEFAULT_OPERATOR_BASE_URL)
    parser.add_argument("--asn-list-base-url", default=DEFAULT_ASN_LIST_BASE_URL)
    parser.add_argument("--asn-prefix-base-url", default=DEFAULT_ASN_PREFIX_BASE_URL)
    parser.add_argument("--ripe-as-names-url", default=DEFAULT_RIPE_AS_NAMES_URL)
    args = parser.parse_args()

    operator_texts = [
        read_source(name, args.operator_dir, args.operator_base_url)
        for name in OPERATOR_NAMES
    ]
    for name, text in zip(OPERATOR_NAMES, operator_texts):
        if not parse_ipv4_networks(text):
            raise RuntimeError(f"operator source contains no IPv4 prefixes: {name}")
    carrier_asns = {
        name: parse_asn_list(read_source(name, args.asn_list_dir, args.asn_list_base_url))
        for name in CARRIER_ASN_NAMES
    }
    for name, asns in carrier_asns.items():
        if not asns:
            raise RuntimeError(f"carrier ASN source is empty: {name}")
    all_asns = sorted({asn for values in carrier_asns.values() for asn in values})
    asn_names = fetch_asn_names(all_asns, args.ripe_as_names_url)
    missing_names = [asn for asn in all_asns if not asn_names.get(asn)]
    if missing_names:
        raise RuntimeError(f"RIPEstat returned no holder for ASN: {missing_names}")
    excluded = classify_excluded_asns(carrier_asns, asn_names)
    excluded_carriers = {carrier for carrier, _asn, _holder in excluded}
    missing_exclusions = sorted(set(CARRIER_ASN_NAMES) - excluded_carriers)
    if missing_exclusions:
        raise RuntimeError(
            f"no IDC/cloud ASN was identified for carrier source: {missing_exclusions}"
        )
    excluded_prefixes = fetch_excluded_prefixes(excluded, args.asn_prefix_base_url)
    networks = build_access_networks(
        operator_texts,
        args.country_file.read_text(encoding="utf-8"),
        excluded_prefixes,
    )
    if not networks:
        raise RuntimeError("generated carrier/CERNET access list is empty")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.audit.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(str(network) for network in networks) + "\n", encoding="utf-8")
    args.audit.write_text(render_audit(excluded), encoding="utf-8")
    print(f"Wrote {args.output} ({len(networks)} IPv4 prefixes)")
    print(f"Wrote {args.audit} ({len(excluded)} excluded ASNs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
