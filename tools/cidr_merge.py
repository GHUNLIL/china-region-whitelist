#!/usr/bin/env python3
"""Merge IPv4 CIDR lists for the bundled data files.

Output = collapse(base ∪ (extra − exclude)). Prefixes listed in --base are
never removed, so excluding a network can only stop new coverage from being
added; it can never shrink what the ASN-based list already allowed.
"""

from __future__ import annotations

import argparse
import ipaddress
import sys
from pathlib import Path


def read_networks(paths: list[Path]) -> list[ipaddress.IPv4Network]:
    networks: list[ipaddress.IPv4Network] = []
    for path in paths:
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.split("#", 1)[0].strip()
            if not line:
                continue
            try:
                network = ipaddress.ip_network(line, strict=False)
            except ValueError:
                continue
            if network.version == 4:
                networks.append(network)
    return list(ipaddress.collapse_addresses(networks))


def subtract(
    networks: list[ipaddress.IPv4Network], removals: list[ipaddress.IPv4Network]
) -> list[ipaddress.IPv4Network]:
    result: list[ipaddress.IPv4Network] = []
    removals = list(ipaddress.collapse_addresses(removals))
    for network in networks:
        parts = [network]
        for removal in removals:
            if not removal.overlaps(network):
                continue
            remaining: list[ipaddress.IPv4Network] = []
            for part in parts:
                if not removal.overlaps(part):
                    remaining.append(part)
                elif not part.subnet_of(removal):
                    remaining.extend(part.address_exclude(removal))
            parts = remaining
        result.extend(parts)
    return list(ipaddress.collapse_addresses(result))


def address_count(networks: list[ipaddress.IPv4Network]) -> int:
    return sum(network.num_addresses for network in networks)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, action="append", default=[], help="CIDR file that is always kept")
    parser.add_argument("--extra", type=Path, action="append", default=[], help="CIDR file added after exclusions")
    parser.add_argument("--exclude", type=Path, action="append", default=[], help="CIDR file removed from --extra")
    parser.add_argument("--previous", type=Path, help="Previously bundled output used for the shrink guard")
    parser.add_argument("--min-ratio", type=float, default=0.95, help="Minimum new/previous address ratio")
    args = parser.parse_args()

    base = read_networks(args.base)
    extra = subtract(read_networks(args.extra), read_networks(args.exclude))
    merged = list(ipaddress.collapse_addresses(base + extra))
    if not merged:
        print("no IPv4 prefixes after merge", file=sys.stderr)
        return 1

    if args.previous and args.previous.exists():
        previous_count = address_count(read_networks([args.previous]))
        merged_count = address_count(merged)
        if previous_count and merged_count < previous_count * args.min_ratio:
            print(
                f"refusing to shrink coverage from {previous_count} to {merged_count} addresses; "
                "upstream data looks incomplete",
                file=sys.stderr,
            )
            return 1

    sys.stdout.write("".join(f"{network}\n" for network in merged))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
