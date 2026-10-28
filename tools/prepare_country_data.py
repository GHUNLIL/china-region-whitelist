#!/usr/bin/env python3
"""Bundle all available country/territory IPv4 allocations for offline use.

CN deliberately retains prepare_data.py's broader mainland routing union.
Other entries use IPdeny RIR-derived country data, not physical geolocation.
"""
import argparse
import io
import ipaddress
from pathlib import Path
import re
import tarfile
import urllib.request

URL = 'https://www.ipdeny.com/ipblocks/data/countries/all-zones.tar.gz'
ROOT = Path(__file__).resolve().parents[1]
NAMES = {'CN': '中国大陆', 'HK': '中国香港', 'MO': '中国澳门', 'TW': '中国台湾',
         'JP': '日本', 'SG': '新加坡', 'US': '美国', 'KR': '韩国', 'GB': '英国',
         'DE': '德国', 'FR': '法国', 'CA': '加拿大', 'AU': '澳大利亚', 'RU': '俄罗斯'}


def parse_archive(payload):
    countries = {}
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
        for member in archive:
            name = Path(member.name).name
            if not member.isfile() or not re.fullmatch(r'[a-z]{2}\.zone', name):
                continue
            networks = []
            for line in archive.extractfile(member).read().decode('ascii').splitlines():
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                network = ipaddress.ip_network(line)
                if network.version != 4 or network.prefixlen == 0:
                    raise ValueError(f'Invalid country IPv4 prefix: {line}')
                networks.append(network)
            if networks:
                countries[name[:2].upper()] = list(ipaddress.collapse_addresses(networks))
    return countries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=ROOT / 'data')
    parser.add_argument('--archive', type=Path, help='Use a downloaded IPdeny archive')
    parser.add_argument('--allow-shrink', action='store_true')
    args = parser.parse_args()
    payload = args.archive.read_bytes() if args.archive else urllib.request.urlopen(URL, timeout=120).read()
    countries = parse_archive(payload)
    if len(countries) < 200 or 'CN' not in countries:
        raise RuntimeError('Incomplete country archive (fewer than 200 countries/territories)')
    target = args.data_dir / 'country'
    if not (target / 'CN.txt').is_file():
        raise RuntimeError('Run prepare_data.py first to build CN.txt')
    # Validate every candidate before replacing any file.
    for code, networks in countries.items():
        old_file = target / f'{code}.txt'
        if code == 'CN' or not old_file.exists() or args.allow_shrink:
            continue
        old = [ipaddress.ip_network(s) for s in old_file.read_text().splitlines() if s and not s.startswith('#')]
        if sum(n.num_addresses for n in networks) < .95 * sum(n.num_addresses for n in old):
            raise RuntimeError(f'{code}: IPv4 coverage fell below 95%; use --allow-shrink after review')
    manifest = args.data_dir / 'countries.tsv'
    if manifest.exists():
        previous = {line.split('\t')[0] for line in manifest.read_text().splitlines() if line and not line.startswith('#')}
        if previous - countries.keys():
            raise RuntimeError(f'Countries disappeared from upstream: {sorted(previous - countries.keys())}')
    for code, networks in countries.items():
        if code != 'CN':
            (target / f'{code}.txt').write_text(''.join(f'{net}\n' for net in networks))
    manifest.write_text('# ISO 3166-1 alpha-2\tname (IPdeny allocation country; CN routing union)\n' +
                        ''.join(f'{code}\t{NAMES.get(code, code)}\n' for code in sorted(countries)))
    print(f'Bundled {len(countries)} countries/territories; preserved CN routing union')


if __name__ == '__main__':
    main()
