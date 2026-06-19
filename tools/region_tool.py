#!/usr/bin/env python3
"""Local region metadata and firewall command helper."""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REGIONS_JSON = ROOT / "data" / "regions.json"
DEFAULT_DATA_DIR = ROOT / "data"
SET_NAME = "cn_region_whitelist"
CHAIN_NAME = "CN_REGION_WHITELIST"
ENTRY_CHAINS = ("INPUT", "FORWARD")
INTERFACE_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}\+?$")


def load_metadata(regions_json: Path) -> dict:
    return json.loads(regions_json.read_text(encoding="utf-8"))


def list_provinces(metadata: dict) -> list[tuple[int, str, str]]:
    return [
        (index, str(province["code"]), str(province["name"]))
        for index, province in enumerate(metadata["provinces"], 1)
    ]


def find_province(metadata: dict, code: str) -> dict:
    for province in metadata["provinces"]:
        if str(province["code"]) == code:
            return province
    raise SystemExit(f"Unknown province code: {code}")


def resolve_province(metadata: dict, selector: str) -> dict:
    selector = selector.strip()
    normalized = normalize_name(selector)
    matches = []
    for index, province in enumerate(metadata["provinces"], 1):
        province_name = str(province["name"])
        if (
            selector == str(index)
            or selector == str(province["code"])
            or selector == province_name
            or normalized == normalize_name(province_name)
        ):
            matches.append(province)
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise SystemExit(f"未找到省份：{selector}")
    raise SystemExit(f"省份名称不唯一：{selector}")


def resolve_city(metadata: dict, province_selector: str, city_selector: str) -> dict:
    province = resolve_province(metadata, province_selector)
    city_selector = city_selector.strip()
    normalized = normalize_name(city_selector)
    for index, city in enumerate(province.get("cities", []), 1):
        city_name = str(city["name"])
        if (
            city_selector == str(index)
            or city_selector == str(city["code"])
            or city_selector == city_name
            or normalized == normalize_name(city_name)
        ):
            return city
    raise SystemExit(f"在 {province['name']} 中未找到城市：{city_selector}")


def normalize_name(name: str) -> str:
    suffixes = [
        "特别行政区",
        "维吾尔自治区",
        "壮族自治区",
        "回族自治区",
        "自治区",
        "省",
        "市",
        "地区",
        "盟",
    ]
    result = name.strip()
    for suffix in suffixes:
        if result.endswith(suffix):
            result = result[: -len(suffix)]
            break
    return result


def list_cities(metadata: dict, province_code: str) -> list[tuple[int, str, str]]:
    province = find_province(metadata, province_code)
    return [
        (index, str(city["code"]), str(city["name"]))
        for index, city in enumerate(province.get("cities", []), 1)
    ]


def find_region_file(metadata: dict, code: str) -> str:
    for province in metadata["provinces"]:
        if str(province["code"]) == code:
            return str(province["file"])
        for city in province.get("cities", []):
            if str(city["code"]) == code:
                return str(city["file"])
    raise SystemExit(f"Unknown region code: {code}")


def collect_cidrs(metadata: dict, data_dir: Path, codes: list[str]) -> list[str]:
    seen: set[str] = set()
    cidrs: list[str] = []

    for code in codes:
        region_file = data_dir / find_region_file(metadata, code)
        if not region_file.exists():
            raise SystemExit(f"Missing region file: {region_file}")
        for raw_line in region_file.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            ipaddress.ip_network(line, strict=False)
            if line not in seen:
                seen.add(line)
                cidrs.append(line)

    if not cidrs:
        raise SystemExit("Selected regions contain no CIDR ranges")
    return cidrs


def validate_interface_name(name: str) -> str:
    if not INTERFACE_RE.fullmatch(name):
        raise SystemExit(f"Invalid network interface name: {name}")
    return name


def remove_jump_command(entry_chain: str) -> str:
    return (
        f"iptables -S {entry_chain} | "
        f"awk '$0 ~ / -j {CHAIN_NAME}( |$)/ {{ sub(/^-A /, \"-D \"); print \"iptables \" $0 }}' | sh"
    )


def add_jump_command(entry_chain: str, args: list[str]) -> str:
    arg_string = " ".join(args + ["-j", CHAIN_NAME])
    return (
        f"iptables -C {entry_chain} {arg_string} 2>/dev/null || "
        f"iptables -I {entry_chain} 1 {arg_string}"
    )


def unique_interface_names(names: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for name in names:
        validated = validate_interface_name(name)
        if validated not in seen:
            seen.add(validated)
            result.append(validated)
    return result


def render_apply_commands(
    cidrs: list[str],
    client_ip: str = "",
    forward_ifaces: list[str] | None = None,
    no_forward: bool = False,
) -> list[str]:
    selected_forward_ifaces = unique_interface_names(forward_ifaces or [])
    if no_forward and selected_forward_ifaces:
        raise SystemExit("--no-forward cannot be used with --forward-iface")

    commands = [
        f"ipset create {SET_NAME} hash:net family inet -exist",
        f"ipset flush {SET_NAME}",
    ]
    for cidr in cidrs:
        commands.append(f"ipset add {SET_NAME} {cidr} -exist")
    if client_ip:
        ipaddress.ip_address(client_ip)
        commands.append(f"ipset add {SET_NAME} {client_ip} -exist")

    commands.extend(
        [
            f"iptables -N {CHAIN_NAME} 2>/dev/null || true",
            remove_jump_command("INPUT"),
            remove_jump_command("FORWARD"),
            f"iptables -F {CHAIN_NAME}",
        ]
    )
    commands.append(add_jump_command("INPUT", []))
    if not no_forward:
        if selected_forward_ifaces:
            for iface in selected_forward_ifaces:
                commands.append(add_jump_command("FORWARD", ["-i", iface]))
                commands.append(add_jump_command("FORWARD", ["-o", iface]))
        else:
            commands.append(add_jump_command("FORWARD", []))
    commands.extend(
        [
            f"iptables -A {CHAIN_NAME} -i lo -j ACCEPT",
            f"iptables -A {CHAIN_NAME} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
            f"iptables -A {CHAIN_NAME} -m set --match-set {SET_NAME} src -j ACCEPT",
            f"iptables -A {CHAIN_NAME} -j REJECT",
        ]
    )
    return commands


def render_clear_commands() -> list[str]:
    commands = [remove_jump_command(entry_chain) for entry_chain in ENTRY_CHAINS]
    commands.extend(
        [
            f"iptables -F {CHAIN_NAME} 2>/dev/null || true",
            f"iptables -X {CHAIN_NAME} 2>/dev/null || true",
            f"ipset destroy {SET_NAME} 2>/dev/null || true",
        ]
    )
    return commands


def print_rows(rows: list[tuple[int, str, str]]) -> None:
    for index, code, name in rows:
        print(f"{index}\t{code}\t{name}")


def show_provinces(metadata: dict) -> None:
    print("可选省份：")
    for index, _code, name in list_provinces(metadata):
        print(f"{index}.{name}")


def show_cities(metadata: dict, province_selector: str) -> None:
    province = resolve_province(metadata, province_selector)
    print(f"{province['name']} 可选城市：")
    print("0.全市" if str(province["name"]).endswith("市") else "0.全省")
    cities = list_cities(metadata, str(province["code"]))
    if not cities:
        print("   该地区暂无市级细分，请选择全省。")
        return
    for index, _code, name in cities:
        print(f"{index}.{name}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--regions-json", type=Path, default=DEFAULT_REGIONS_JSON)
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("list-provinces")

    subparsers.add_parser("show-provinces")

    cities = subparsers.add_parser("list-cities")
    cities.add_argument("province_code")

    show_cities_parser = subparsers.add_parser("show-cities")
    show_cities_parser.add_argument("province_selector")

    resolve_province_parser = subparsers.add_parser("resolve-province")
    resolve_province_parser.add_argument("selector")

    resolve_city_parser = subparsers.add_parser("resolve-city")
    resolve_city_parser.add_argument("province_selector")
    resolve_city_parser.add_argument("city_selector")

    cidrs = subparsers.add_parser("collect-cidrs")
    cidrs.add_argument("codes", nargs="+")

    render = subparsers.add_parser("render-apply")
    render.add_argument("--client-ip", default="")
    render.add_argument(
        "--forward-iface",
        action="append",
        default=[],
        help="limit FORWARD management to packets entering or leaving this interface",
    )
    render.add_argument("--no-forward", action="store_true", help="do not manage FORWARD traffic")
    render.add_argument("codes", nargs="+")

    subparsers.add_parser("render-clear")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    metadata = load_metadata(args.regions_json)

    if args.command == "list-provinces":
        print_rows(list_provinces(metadata))
    elif args.command == "show-provinces":
        show_provinces(metadata)
    elif args.command == "list-cities":
        print_rows(list_cities(metadata, args.province_code))
    elif args.command == "show-cities":
        show_cities(metadata, args.province_selector)
    elif args.command == "resolve-province":
        print(resolve_province(metadata, args.selector)["code"])
    elif args.command == "resolve-city":
        print(resolve_city(metadata, args.province_selector, args.city_selector)["code"])
    elif args.command == "collect-cidrs":
        print("\n".join(collect_cidrs(metadata, args.data_dir, args.codes)))
    elif args.command == "render-apply":
        cidrs = collect_cidrs(metadata, args.data_dir, args.codes)
        print(
            "\n".join(
                render_apply_commands(
                    cidrs,
                    args.client_ip,
                    args.forward_iface,
                    args.no_forward,
                )
            )
        )
    elif args.command == "render-clear":
        print("\n".join(render_clear_commands()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
