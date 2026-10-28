#!/usr/bin/env bash
# Run only in a fresh network namespace: sudo unshare --net bash tests/test_firewall_netns.sh
set -Eeuo pipefail
trap 'echo "Network test failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
[[ "$(ip -o link show | wc -l)" -eq 1 ]] || { echo 'Refusing to run outside an empty network namespace.' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tools/firewall_lib.sh"
DATA_DIR="${ROOT}/tests/fixtures"
CN_COUNTRY_FILE="${DATA_DIR}/country/CN.txt"
CN_BUNDLED_ASN_DIR="${DATA_DIR}/asn"
CN_REGIONS_TSV="${DATA_DIR}/regions.tsv"
client="crw-test-$$"
backend_ns="crw-target-$$"
script_file="$(mktemp)"
server_pid=""
cleanup() {
  [[ -z "${server_pid}" ]] || kill "${server_pid}" 2>/dev/null || true
  ip netns pids "${client}" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns pids "${backend_ns}" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns del "${client}" 2>/dev/null || true
  ip netns del "${backend_ns}" 2>/dev/null || true
  rm -f "${script_file}"
}
trap cleanup EXIT
ip link set lo up
ip netns add "${client}"
ip link add srv0 type veth peer name cli0
ip link set cli0 netns "${client}"
ip link set srv0 up
for addr in 198.18.0.1/24 192.0.2.1/24 203.0.113.1/24; do ip addr add "${addr}" dev srv0; done
ip -6 addr add fd00:1234::1/64 dev srv0 nodad
ip -n "${client}" link set lo up
ip -n "${client}" link set cli0 up
for addr in 198.18.0.2/24 192.0.2.2/24 203.0.113.2/24; do ip -n "${client}" addr add "${addr}" dev cli0; done
ip -n "${client}" -6 addr add fd00:1234::2/64 dev cli0 nodad
ip netns add "${backend_ns}"
ip link add back0 type veth peer name target0
ip link set target0 netns "${backend_ns}"
ip link set back0 up
ip addr add 10.10.0.1/24 dev back0
ip -n "${backend_ns}" link set lo up
ip -n "${backend_ns}" link set target0 up
ip -n "${backend_ns}" addr add 10.10.0.2/24 dev target0
ip -n "${backend_ns}" route add default via 10.10.0.1
sysctl -qw net.ipv4.ip_forward=1
nft -f - <<'NFT'
table ip test_nat {
  chain prerouting {
    type nat hook prerouting priority dstnat;
    tcp dport 18081 dnat to 10.10.0.2:18080
    udp dport 18081 dnat to 10.10.0.2:18080
  }
}
NFT
# Echo servers make both TCP and UDP checks independent of external services.
server_code='import socket,threading,time,sys

def serve(kind):
 s=socket.socket(socket.AF_INET,kind); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((sys.argv[1],18080))
 if kind==socket.SOCK_STREAM:
  s.listen()
  while True:
   c,a=s.accept(); c.sendall(b"ok"); c.close()
 else:
  while True:
   data,a=s.recvfrom(100); s.sendto(b"ok",a)
for kind in (socket.SOCK_STREAM,socket.SOCK_DGRAM): threading.Thread(target=serve,args=(kind,),daemon=True).start()
while True: time.sleep(60)'
python3 -c "${server_code}" 198.18.0.1 &
server_pid=$!
ip netns exec "${backend_ns}" python3 -c "${server_code}" 10.10.0.2 &
sleep 1
probe() {
  ip netns exec "${client}" python3 - "$@" <<'PY'
import socket,sys
source,port,protocol=sys.argv[1:]
s=socket.socket(socket.AF_INET, socket.SOCK_STREAM if protocol=='tcp' else socket.SOCK_DGRAM)
s.settimeout(1)
s.bind((source,0))
try:
 s.connect(('198.18.0.1',int(port)))
 if protocol=='udp': s.send(b'probe')
 assert s.recv(10)==b'ok'
except (OSError,AssertionError) as error:
 print(f"Probe {source}:{port}/{protocol}: {error}",file=sys.stderr)
 sys.exit(1)
PY
}
expect_blocked() {
  if probe "$@"; then echo "Unexpected access: $*" >&2; exit 1; fi
}
# Baseline proves the routes and services work before applying policy.
echo "Checking TCP INPUT baseline"
probe 192.0.2.2 18080 tcp
echo "Checking UDP DNAT baseline"
probe 192.0.2.2 18081 udp
ip netns exec "${client}" ping -6 -e 4320 -c 1 -W 1 fd00:1234::1 >/dev/null
for backend in nft iptables; do
  echo "Applying ${backend} country policy"
  CN_FIREWALL_BACKEND="${backend}"
  CN_ALLOWED_COUNTRIES='CN JP'
  CN_GLOBAL_IP_RULES='allow:192.0.2.2'
  CN_PORT_EXCEPTIONS='18080=allow:192.0.2.2;18081=allow:192.0.2.2'
  cn_render_apply_commands '' all '' '' '' CN JP > "${script_file}"
  bash -e -o pipefail "${script_file}"
  for port in 18080 18081; do
    for protocol in tcp udp; do
      probe 198.18.0.2 "${port}" "${protocol}"
      probe 203.0.113.2 "${port}" "${protocol}"
      expect_blocked 192.0.2.2 "${port}" "${protocol}"
    done
  done
  # A fresh echo identifier avoids conntrack's established-connection bypass.
  if ip netns exec "${client}" ping -6 -e 4321 -c 1 -W 1 fd00:1234::1 >/dev/null 2>&1; then
    echo "${backend}: IPv6 bypass" >&2; exit 1
  fi
  cn_render_best_effort_clear_commands > "${script_file}"
  bash -e -o pipefail "${script_file}"
  probe 192.0.2.2 18080 tcp
  probe 192.0.2.2 18081 udp
  echo "PASS ${backend}: TCP/UDP INPUT + DNAT, country union, allow-exception precedence, IPv6 and cleanup"
done
