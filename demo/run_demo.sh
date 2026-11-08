#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_demo.sh -- real Linux traffic through the switch RTL      (make demo)
#
#   ns0: 10.0.0.1 <-> tap0 <-> | port 0                |
#   ns1: 10.0.0.2 <-> tap1 <-> | port 1   switch RTL   |
#   ns2: 10.0.0.3 <-> tap2 <-> | port 2   (Verilator)  |
#   ns3: 10.0.0.4 <-> tap3 <-> | port 3                |
#
# No sudo: everything runs inside a user namespace, where this script is root
# over its own network namespaces only. Each host is a network namespace held
# open by a `sleep`; its TAP device is moved into it after the harness has
# opened the device, and the harness's file stays attached across the move.
#
# Traffic: ping between three pairs of hosts, then a TCP transfer checked
# end to end. Results go to build/demo/; demo/check_capture.py then checks
# that every frame went exactly where a learning switch should send it.
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/demo
SIM=${SIM:-build/obj_demo/tap_switch}   # SIM=... runs another build, e.g. one with a bug

if [ "${1:-}" != "--inside" ]; then
    [ -x "$SIM" ] || { echo "build the harness first: make demo"; exit 1; }
    rm -rf "$OUT"; mkdir -p "$OUT"
    exec unshare --user --map-root-user --net "$0" --inside
fi

ip link set lo up
"$SIM" "$OUT" > "$OUT/switch.log" 2>&1 &
SW=$!
NS=()
cleanup() {
    kill -TERM "$SW" 2>/dev/null || true
    wait "$SW" 2>/dev/null || true
    for p in "${NS[@]}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT
for _ in $(seq 100); do grep -q READY "$OUT/switch.log" 2>/dev/null && break; sleep 0.1; done
grep -q READY "$OUT/switch.log" || { cat "$OUT/switch.log"; echo "RESULT: FAIL (harness did not start)"; exit 1; }

# one network namespace per host
for i in 0 1 2 3; do
    unshare --net sleep infinity &
    NS[$i]=$!
done
sleep 0.2
in_ns() { local i=$1; shift; nsenter --target "${NS[$i]}" --net "$@"; }
for i in 0 1 2 3; do
    ip link set "tap$i" netns "${NS[$i]}"
    # IPv6 off, so the captures hold only this demo's traffic
    in_ns $i sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 "net.ipv6.conf.tap$i.disable_ipv6=1"
    in_ns $i ip link set "tap$i" address "02:00:00:00:00:0$((i + 1))"
    in_ns $i ip addr add "10.0.0.$((i + 1))/24" dev "tap$i"
    in_ns $i ip link set "tap$i" up
done
echo "hosts up: ns0-ns3 = 10.0.0.1-10.0.0.4 (MAC 02:00:00:00:00:01-04), each on its own switch port"

fail=0
step() { echo; echo "== $*"; }
ping_test() {
    local from=$1 to=$2
    step "ns$from ping 10.0.0.$((to + 1))"
    if in_ns "$from" ping -c 3 -i 0.5 -W 5 "10.0.0.$((to + 1))" | sed 's/^/   /' | grep -E "bytes from|transmitted"; then :; else fail=1; fi
    in_ns "$from" ping -c 1 -W 5 "10.0.0.$((to + 1))" > /dev/null || { echo "   FAIL"; fail=1; }
}
ping_test 0 1
ping_test 2 3
ping_test 3 0

step "TCP: ns1 sends 256 KB to ns2, which returns its SHA-256"
in_ns 2 python3 demo/tcp_check.py server 10.0.0.3 > "$OUT/tcp_server.log" 2>&1 &
SRV=$!
sleep 0.5
if in_ns 1 timeout 120 python3 demo/tcp_check.py client 10.0.0.3 | sed 's/^/   /'; then :; else echo "   FAIL"; fail=1; fi
wait "$SRV" || fail=1

step "ARP tables learned by the hosts"
for i in 0 1 2 3; do echo "   ns$i: $(in_ns $i ip neigh show dev "tap$i" | awk '{print $1" "$3}' | paste -sd' ')"; done

cleanup
trap - EXIT
step "switch"
sed -n '/---- summary ----/,$p' "$OUT/switch.log" | sed 's/^/   /'
grep ERROR "$OUT/switch.log" && fail=1

step "capture check"
python3 demo/check_capture.py "$OUT" || fail=1
echo
echo "captures for Wireshark: $OUT/port0.pcap ... port3.pcap"
[ $fail = 0 ] && echo "RESULT: PASS (real Linux traffic through the switch RTL)" || { echo "RESULT: FAIL"; exit 1; }
