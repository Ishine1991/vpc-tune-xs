#!/usr/bin/env bash
# Real packet tests; all links, IFB and qdiscs live in disposable namespaces.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
unshare --net --mount --propagation private bash -s -- "$repo" <<'TEST'
set -euo pipefail
repo=$1
mount -t sysfs sysfs /sys
work=$(mktemp -d /tmp/pacing-duplex.XXXXXX)
peer_pid="" server_pid=""
cleanup() {
    [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
    [[ -z "$peer_pid" ]] || kill "$peer_pid" 2>/dev/null || true
    rm -rf -- "$work"
}
trap cleanup EXIT
source <(sed -n '/^# TCP\/FQ 每流限速：/,/^#启用BBR+cake/{ /^#启用BBR+cake/d; p; }' "$repo/net-tcp-tune.sh")
PACING_CONFIG_FILE="$work/egress.json"
PACING_STATE_DIR="$work/states"
PACING_POLICY_FILE="$work/policy.json"
PACING_SYSCTL_FILE="$work/legacy.conf"
PACING_LOCK_FILE="$work/lock"
PACING_INSTALLED_SCRIPT="$work/installed.sh"
PACING_SCRIPT_SOURCE="$repo/net-tcp-tune.sh"
PACING_SERVICE_FILE="$work/pacing.service"
PACING_BOOT_RETRY_COUNT=1
PACING_BOOT_RETRY_SLEEP=0
systemctl() { :; }
ip link set lo up
unshare --net sleep 600 &
peer_pid=$!
for ((i=0; i<100; i++)); do
    [[ "$(readlink /proc/"$peer_pid"/ns/net)" != "$(readlink /proc/self/ns/net)" ]] && break
    sleep .02
done
ip link add srv type veth peer name cli
ip link set cli netns "$peer_pid"
ip addr add 192.0.2.1/24 dev srv
ip -6 addr add fd00:39::1/64 dev srv nodad
ip link set srv up
nsenter -t "$peer_pid" -n ip link set lo up
nsenter -t "$peer_pid" -n ip addr add 192.0.2.2/24 dev cli
nsenter -t "$peer_pid" -n ip -6 addr add fd00:39::2/64 dev cli nodad
nsenter -t "$peer_pid" -n ip link set cli up
tc qdisc add dev srv root handle 1: fq limit 2345 flow_limit 67
before_tcp=$(sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_congestion_control)
ifb="ntifb$(pacing_ifindex srv)"
assert_clean_rx() {
    if [[ -e "$(pacing_rx_file srv)" ]]; then
        cat "$(pacing_rx_file srv)"
        ip -j -d link show dev "$ifb" || true
        tc -j -d qdisc show dev srv
    fi
    [[ ! -e "$(pacing_rx_file srv)" ]]
    ! ip link show dev "$ifb" >/dev/null 2>&1
    tc -j qdisc show dev srv | jq -e 'all(.[]; .kind != "ingress" and .kind != "clsact")' >/dev/null
}

# Existing ingress/clsact and occupied interface names must survive rejection.
tc qdisc add dev srv clsact
before=$(tc -j qdisc show dev srv)
if pacing_apply_duplex srv 1048576; then exit 1; fi
[[ "$(tc -j qdisc show dev srv)" == "$before" ]]
tc qdisc del dev srv clsact
ip link add name "$ifb" type dummy
if pacing_apply_duplex srv 1048576; then exit 1; fi
ip -j -d link show dev "$ifb" | jq -e '.[0].linkinfo.info_kind == "dummy"' >/dev/null
ip link del dev "$ifb"

# IFB creation may still fail despite module support (e.g. container policy).
# A failed attempt with no resources must not leave a journal blocking retries.
ip() {
    if [[ "$1 $2 $3 $4" == "link add name $ifb" ]]; then return 1; fi
    command ip "$@"
}
if pacing_apply_duplex srv 1048576; then exit 1; fi
unset -f ip
assert_clean_rx
[[ $(pacing_layout_rate "$(pacing_read_layout srv)") == 4294967295 ]]

# A full disk after successful ingress creation must not strand our resources.
# Fail all ownership-journal writes, not just a one-shot write failure.
eval "$(declare -f pacing_write_file | sed '1s/pacing_write_file/pacing_test_write_file/')"
pacing_write_file() {
    if [[ "$1" == "$(pacing_rx_file srv)" ]] &&
       jq -e '.ingress_owned == true' <<< "$3" >/dev/null; then
        return 1
    fi
    pacing_test_write_file "$@"
}
if pacing_apply_duplex srv 1048576; then exit 1; fi
unset -f pacing_write_file
eval "$(declare -f pacing_test_write_file | sed '1s/pacing_test_write_file/pacing_write_file/')"
unset -f pacing_test_write_file
assert_clean_rx
[[ $(pacing_layout_rate "$(pacing_read_layout srv)") == 4294967295 ]]

# Fail after ingress attachment but before redirect; remove only our resources.
tc() {
    if [[ "$1 $2" == "filter add" ]]; then return 1; fi
    command tc "$@"
}
if pacing_apply_duplex srv 1048576; then exit 1; fi
unset -f tc
assert_clean_rx

# If egress fails, new ingress must be rolled back as well.
tc() {
    if [[ "$1 $2 $3 $4" == "qdisc change dev srv" ]]; then return 1; fi
    command tc "$@"
}
if pacing_apply_duplex srv 1048576; then exit 1; fi
unset -f tc
assert_clean_rx
[[ $(pacing_layout_rate "$(pacing_read_layout srv)") == 4294967295 ]]

iperf3 -s > "$work/server.log" 2>&1 &
server_pid=$!
measure() {
    local label="$1" address="$2" min="$3" max="$4"
    shift 4
    nsenter -t "$peer_pid" -n iperf3 -c "$address" -t 4 -O 1 -J "$@" > "$work/result.json"
    python3 - "$work/result.json" "$label" "$min" "$max" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert "error" not in data, data
end = data["end"]
rate = end.get("sum_received", end.get("sum", {}))["bits_per_second"]
print(f"{sys.argv[2]}: {rate / 1e6:.3f} Mbps")
assert float(sys.argv[3]) <= rate <= float(sys.argv[4]), data
PY
}
measure baseline 192.0.2.1 25000000 1000000000000
pacing_apply_persistent srv 1048576 both
tc -j filter show dev srv ingress
pacing_rx_verify "$(pacing_rx_read srv)"
jq -e '.ingress == true' "$PACING_POLICY_FILE" >/dev/null
# 1 MiB/s ~= 8.39 Mbps. Receiver payload is slightly lower than wire rate.
measure tcp-upload-v4 192.0.2.1 4000000 11500000
measure tcp-download-v4 192.0.2.1 4000000 11500000 -R
measure tcp-upload-v6 fd00:39::1 4000000 11500000
measure tcp-download-v6 fd00:39::1 4000000 11500000 -R
measure tcp-two-upload-flows 192.0.2.1 12000000 23000000 -P 2
measure tcp-two-download-flows 192.0.2.1 12000000 23000000 -P 2 -R
measure udp-upload-v4 192.0.2.1 3500000 11500000 -u -b 30M -l 1200
measure udp-download-v6 fd00:39::1 3500000 11500000 -u -b 30M -l 1200 -R

# Modification rollback must preserve the old rate in BOTH directions.
tc() {
    if [[ "$1 $2 $3 $4" == "qdisc change dev srv" && "${*: -1}" == 16777216bit ]]; then return 1; fi
    command tc "$@"
}
if pacing_apply_duplex srv 2097152; then exit 1; fi
unset -f tc
[[ $(pacing_layout_rate "$(pacing_read_layout srv)") == 1048576 ]]
[[ $(jq -r .rate <<< "$(pacing_rx_read srv)") == 1048576 ]]
pacing_rx_verify "$(pacing_rx_read srv)"

pacing_apply_persistent srv 2097152 both
measure modified-upload 192.0.2.1 11500000 22500000

# A foreign classifier added after setup must not be deleted by cleanup.
tc filter add dev srv ingress protocol all pref 49140 handle 2 matchall action pass
if pacing_rx_disable srv; then exit 1; fi
tc -j filter show dev srv ingress | jq -e 'any(.[]; .pref == 49140)' >/dev/null
tc filter del dev srv ingress protocol all pref 49140 handle 2 matchall

# Simulate reboot: kernel configuration disappears, persistent records remain.
saved_rx=$(cat "$(pacing_rx_file srv)")
saved_tx=$(cat "$PACING_CONFIG_FILE")
pacing_rx_disable srv
pacing_disable
pacing_write_file "$(pacing_rx_file srv)" 600 "$saved_rx"
pacing_write_file "$PACING_CONFIG_FILE" 600 "$saved_tx"
pacing_boot_id() { echo simulated-next-boot; }
pacing_restore_boot
pacing_rx_verify "$(pacing_rx_read srv)"
[[ $(pacing_layout_rate "$(pacing_read_layout srv)") == 2097152 ]]
pacing_restore_boot # idempotent in the same boot
measure restored-download 192.0.2.1 11500000 22500000 -R

# A second managed interface must have its own IFB; disabling it leaves srv.
ip link add srv2 type dummy
ip link set srv2 up
tc qdisc replace dev srv2 root handle 1: fq
pacing_apply_persistent srv2 1048576 both
second_ifb=$(jq -r .ifb <<< "$(pacing_rx_read srv2)")
[[ "$second_ifb" != "$ifb" ]]
pacing_disable_iface srv2
! ip link show dev "$second_ifb" >/dev/null 2>&1
pacing_rx_verify "$(pacing_rx_read srv)"
jq -e '.items|length == 1 and .[0].iface == "srv" and .[0].ingress == true' "$PACING_POLICY_FILE" >/dev/null

pacing_disable_all_locked
assert_clean_rx
[[ ! -e "$PACING_POLICY_FILE" && ! -e "$PACING_CONFIG_FILE" ]]
[[ $(pacing_layout_rate "$(pacing_read_layout srv)") == 4294967295 ]]
measure disabled-upload 192.0.2.1 25000000 1000000000000
measure disabled-download 192.0.2.1 25000000 1000000000000 -R
root=$(pacing_read_root srv)
jq -e '.options.limit == 2345 and .options.flow_limit == 67' <<< "$root" >/dev/null
[[ "$before_tcp" == "$(sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_congestion_control)" ]]
echo "PASS: bidirectional TCP/UDP throughput, IPv4/IPv6, per-flow isolation, rollback, boot restore, conflicts and cleanup."
TEST
