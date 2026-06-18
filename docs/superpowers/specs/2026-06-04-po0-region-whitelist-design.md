# po0 Region Whitelist Design

## Goal

Build a local-first one-click script for po0 servers that allows only selected mainland China provinces or cities to access the server. All inbound ports are denied by default unless the source IP is in the selected regional whitelist.

## Constraints

- Server-side execution must avoid external network access.
- Data files must be bundled locally.
- The script must be interactive: choose province first, then choose full province or one or more cities.
- The firewall policy must apply to all inbound ports.
- The script must reduce the risk of locking out the current SSH session.

## Architecture

- `install.sh` is the user-facing entrypoint.
- `data/regions.json` maps province and city names to local CIDR text files.
- `data/regions/*.txt` contains locally bundled CIDR ranges.
- `tools/prepare_data.py` prepares local data on a machine with network access, using metowolf/iplist city files when available and copying the local `ipipfree.ipdb` file as an offline reference asset.
- `tools/firewall_lib.sh` contains shell helpers for loading regions, resolving CIDR files, generating ipset input, and rendering firewall commands.
- Tests validate data parsing and command generation without touching the live firewall.

## Firewall Behavior

The applied policy uses `ipset` for IP ranges and `iptables` for enforcement:

- allow loopback traffic
- allow established and related traffic
- allow source IPs in the selected `po0_region_whitelist` set
- reject all other inbound traffic

Before applying, the script detects the current SSH client IP from `SSH_CONNECTION` and offers to add it to the whitelist set for the current rule application. This protects active maintenance sessions when the operator's current IP is outside the selected region.

## Commands

- `./install.sh apply`: interactive selection and firewall application
- `./install.sh dry-run`: interactive selection and print commands only
- `./install.sh status`: show current ipset and iptables state
- `./install.sh clear`: remove the managed rules and set

## Error Handling

- The script exits if not run as root for operations that modify firewall state.
- Missing `iptables` or `ipset` is reported with install hints, but the script does not fetch external resources itself.
- Missing or empty region files cause a clear error before firewall changes are applied.
- `dry-run` can be used without root to verify choices and rendered commands.

## Testing

Automated tests cover:

- parsing province and city metadata
- resolving full-province and multi-city selections
- generating unique CIDR lists
- rendering firewall commands for dry-run

Manual verification covers:

- `dry-run` output
- syntax check with `bash -n`
- shell lint where available
