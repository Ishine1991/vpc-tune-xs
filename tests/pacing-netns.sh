#!/usr/bin/env bash
# Optional real-kernel regression test, entirely inside a new network namespace.
# Debian dependencies: iproute2 jq util-linux. Run: sudo bash tests/pacing-netns.sh
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for tool in unshare mount ip tc jq; do command -v "$tool" >/dev/null; done
[[ $EUID == 0 ]] || { echo 'Run as root to create an isolated network namespace.' >&2; exit 1; }
unshare --net --mount --propagation private bash -s -- "$repo" <<'TEST'
set -euo pipefail
repo=$1
# sysfs must be mounted in the new network namespace to expose its interfaces.
# The private mount namespace prevents changing the host's /sys mount.
mount -t sysfs sysfs /sys
work=$(mktemp -d /tmp/pacing-netns.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
source <(sed -n '/^# TCP\/FQ 每流限速：/,/^#启用BBR+cake/{ /^#启用BBR+cake/d; p; }' "$repo/net-tcp-tune.sh")
PACING_CONFIG_FILE="$work/state.json"
PACING_SYSCTL_FILE="$work/legacy.conf"
PACING_LOCK_FILE="$work/lock"
ip link add pacingdummy type dummy
ip link set pacingdummy up
tc qdisc replace dev pacingdummy root fq limit 1234 flow_limit 45
before_tcp=$(sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_congestion_control)
pacing_locked pacing_apply_rate pacingdummy 10485760
[[ $(pacing_root_rate "$(pacing_read_root pacingdummy)") == 10485760 ]]
pacing_locked pacing_apply_rate pacingdummy 20971520
[[ $(pacing_root_rate "$(pacing_read_root pacingdummy)") == 20971520 ]]
pacing_locked pacing_disable
root=$(pacing_read_root pacingdummy)
[[ $(pacing_root_rate "$root") == 4294967295 ]]
jq -e '.options.limit == 1234 and .options.flow_limit == 45' <<< "$root" >/dev/null
[[ "$before_tcp" == "$(sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_congestion_control)" ]]
[[ ! -e "$PACING_CONFIG_FILE" ]]

# CI sets default_qdisc=fq on its disposable runner, not on a production host.
# A nonzero txqueuelen makes veth activate its automatic multiqueue qdisc.
if [[ ${PACING_TEST_DEFAULT_FQ:-0} == 1 ]]; then
    ip link add pacingzero numtxqueues 2 type veth peer name pacingzerop numtxqueues 2
    ip link set pacingzero txqueuelen 1000
    ip link set pacingzero up
    zero=$(tc -j -d qdisc show dev pacingzero)
    echo "Automatic kernel layout: $zero"
    jq -e 'any(.[]; .kind == "mq" and .root == true and .handle == "0:") and
      ([.[]|select(.kind == "fq" and .handle == "0:")]|length == 2)' <<< "$zero" >/dev/null
    pacing_locked pacing_migrate_zero_mq pacingzero
    pacing_locked pacing_apply_rate pacingzero 20480
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingzero)") == 20480 ]]
    pacing_locked pacing_apply_rate pacingzero 20971520
    pacing_locked pacing_disable
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingzero)") == 4294967295 ]]
    # Simulate fresh automatic qdiscs at next boot and exercise authorized restore.
    tc qdisc del dev pacingzero root
    PACING_POLICY_FILE="$work/policy.json"
    printf '%s\n' '{"version":1,"iface":"pacingzero","rate":20480}' > "$PACING_POLICY_FILE"
    pacing_locked pacing_restore_boot
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingzero)") == 20480 ]]
    pacing_locked pacing_disable
fi

# Explicit nonzero mq + FQ leaf layout.
ip link add pacingmq numtxqueues 2 type veth peer name pacingpeer numtxqueues 2
ip link set pacingmq up
tc qdisc replace dev pacingmq root handle 1: mq
tc qdisc replace dev pacingmq parent 1:1 fq limit 2345 flow_limit 67
tc qdisc replace dev pacingmq parent 1:2 fq limit 2345 flow_limit 67
pacing_locked pacing_apply_rate pacingmq 10485760
layout=$(pacing_read_layout pacingmq)
[[ $(jq -r .topology <<< "$layout") == mq-fq ]]
[[ $(jq -r '.targets | length' <<< "$layout") == 2 ]]
jq -e 'all(.targets[]; .rate == 10485760)' <<< "$layout" >/dev/null
pacing_locked pacing_disable
layout=$(pacing_read_layout pacingmq)
jq -e 'all(.targets[]; .rate == 4294967295)' <<< "$layout" >/dev/null
leaves=$(tc -j qdisc show dev pacingmq | jq '[.[] | select(.parent != null)]')
jq -e 'length == 2 and all(.[]; .kind == "fq" and .options.limit == 2345 and .options.flow_limit == 67)' \
    <<< "$leaves" >/dev/null
[[ "$before_tcp" == "$(sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_congestion_control)" ]]
[[ ! -e "$PACING_CONFIG_FILE" ]]
echo 'PASS: root FQ and mq+FQ leaf limits change in place, reset explicitly, and preserve TCP/qdisc parameters.'
TEST
