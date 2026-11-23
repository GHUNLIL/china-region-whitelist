#!/usr/bin/env python3
"""Bundle APNIC mainland-CN IPv6 allocations; never infer countries from names."""
import argparse
import ipaddress
from pathlib import Path
import urllib.request

URL = 'https://ftp.apnic.net/stats/apnic/delegated-apnic-latest'
ROOT = Path(__file__).resolve().parents[1]


def parse_delegations(text):
    networks = []
    for line in text.splitlines():
        fields = line.split('|')
        if len(fields) < 7 or fields[1:3] != ['CN', 'ipv6'] or fields[6] not in ('allocated', 'assigned'):
            continue
        net = ipaddress.ip_network(fields[3] + '/' + fields[4])
        if net.version != 6 or net.prefixlen < 16 or not net.subnet_of(ipaddress.ip_network('2000::/3')):
            raise ValueError('Invalid CN IPv6 allocation')
        networks.append(net)
    return list(ipaddress.collapse_addresses(networks))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=ROOT / 'data')
    parser.add_argument('--delegations', type=Path)
    args = parser.parse_args()
    text = args.delegations.read_text() if args.delegations else urllib.request.urlopen(URL, timeout=90).read().decode('ascii')
    networks = parse_delegations(text)
    if len(networks) < 100:
        raise RuntimeError('Incomplete APNIC CN IPv6 data; keeping previous bundle')
    target = args.data_dir / 'country6' / 'CN.txt'
    if target.exists():
        old = [ipaddress.ip_network(s) for s in target.read_text().splitlines() if s and not s.startswith('#')]
        if sum(n.num_addresses for n in networks) < .95 * sum(n.num_addresses for n in old):
            raise RuntimeError('CN IPv6 coverage fell below 95%; keeping previous bundle')
    target.parent.mkdir(parents=True, exist_ok=True)
    pending = target.with_suffix('.tmp')
    pending.write_text(''.join(f'{n}\n' for n in networks))
    pending.replace(target)
    print(f'Bundled {len(networks)} CN IPv6 prefixes from APNIC')


if __name__ == '__main__':
    main()
