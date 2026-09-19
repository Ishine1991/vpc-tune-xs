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
PACING_STATE_DIR="$work/states"
PACING_BOOT_RETRY_COUNT=5
PACING_BOOT_RETRY_SLEEP=0
mkdir -p -- "$PACING_STATE_DIR"
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
# Multi-queue dummy auto-attaches mq + FQ with kernel zero handles; TAP is fallback.
if [[ ${PACING_TEST_DEFAULT_FQ:-0} == 1 ]]; then
    # A single-queue TAP reproduces the reported default root FQ (handle 0:).
    ip tuntap add dev pacingroot mode tap
    ip link set pacingroot up
    root=$(pacing_read_root pacingroot)
    jq -e '.kind == "fq" and .handle == "0:"' <<< "$root" >/dev/null
    pacing_locked pacing_prepare_and_apply pacingroot 102400
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingroot)") == 102400 ]]
    pacing_locked pacing_disable
    pacing_fq_options_match "$(jq -c .options <<< "$(pacing_read_root pacingroot)")" \
        "$(jq -c .options <<< "$root")"
    ip link add pacingzero numtxqueues 2 type dummy
    ip link set pacingzero up
    zero=$(tc -j -d qdisc show dev pacingzero)
    echo "Automatic dummy layout: $zero"
    if ! jq -e 'any(.[]; .kind == "mq" and .root == true and .handle == "0:") and
      ([.[]|select(.kind == "fq" and .handle == "0:")]|length >= 1)' <<< "$zero" >/dev/null; then
        ip link del pacingzero
        ip tuntap add dev pacingzero mode tap multi_queue
        ip link set pacingzero up
        zero=$(tc -j -d qdisc show dev pacingzero)
        echo "Automatic TAP layout: $zero"
        jq -e 'any(.[]; .kind == "mq" and .root == true and .handle == "0:") and
          ([.[]|select(.kind == "fq" and .handle == "0:")]|length >= 1)' <<< "$zero" >/dev/null
    fi
    # Migrating a second interface must not reject, archive, or remove the
    # first interface's active recovery record.
    pacing_locked pacing_apply_rate pacingroot 102400
    saved_root_state=$(cat "$PACING_CONFIG_FILE")
    pacing_locked pacing_migrate_zero_mq pacingzero
    [[ $(cat "$PACING_CONFIG_FILE") == "$saved_root_state" ]]
    pacing_locked pacing_disable
    pacing_locked pacing_apply_rate pacingzero 20480
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingzero)") == 20480 ]]
    pacing_locked pacing_apply_rate pacingzero 20971520
    pacing_locked pacing_disable
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingzero)") == 4294967295 ]]
    # Simulate a half-finished migration: nonzero mq root, leaves still handle 0:.
    root=$(jq -r '.[]|select(.root==true)|.handle' <<< "$(tc -j qdisc show dev pacingzero)")
    root_hex=${root%:}
    # Passing handle 0: to replace allocates a handle; recreating mq generates
    # genuine kernel-owned zero-handle leaves instead.
    tc qdisc del dev pacingzero root
    tc qdisc replace dev pacingzero root handle "$root" mq
    jq -e --arg root "$root" 'any(.[]; .root==true and .handle==$root) and
      all(.[]|select(.parent!=null); .handle=="0:")' <<< "$(tc -j qdisc show dev pacingzero)" >/dev/null
    pacing_locked pacing_migrate_zero_mq pacingzero
    pacing_require_addressable "$(pacing_read_layout pacingzero)"
    # Option 1 path: recreate default zero handles, then prepare+apply in one step.
    tc qdisc del dev pacingzero root
    pacing_locked pacing_prepare_and_apply pacingzero 10485760
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingzero)") == 10485760 ]]
    pacing_locked pacing_disable
    # Simulate fresh automatic qdiscs at next boot and exercise authorized restore.
    tc qdisc del dev pacingzero root
    PACING_POLICY_FILE="$work/policy.json"
    printf '%s\n' '{"version":1,"iface":"pacingzero","rate":20480}' > "$PACING_POLICY_FILE"
    rm -f -- "${PACING_CONFIG_FILE}.migrate-pacingzero"
    pacing_locked pacing_restore_boot
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingzero)") == 20480 ]]
    pacing_locked pacing_disable
fi

# Real kernel-created mq + fq_codel, matching the AWS ens5 report.
if [[ ${PACING_TEST_DEFAULT_CODEL:-0} == 1 ]]; then
    ip link add pacingaws numtxqueues 2 type dummy
    ip link set pacingaws up
    data=$(tc -j -d qdisc show dev pacingaws)
    if ! pacing_codel_layout "$data" >/dev/null; then
        ip link del pacingaws
        ip tuntap add dev pacingaws mode tap multi_queue
        ip link set pacingaws up
        data=$(tc -j -d qdisc show dev pacingaws)
    fi
    pacing_codel_layout "$data" >/dev/null
    jq -e 'all(.[]; .handle == "0:")' <<< "$data" >/dev/null
    # TAP fallback can have one TX queue; fail its last leaf, not a guessed :2.
    fail_minor=$(jq -r '[.[]|select(.parent!=null)|.parent|split(":")|last]|sort|last' <<< "$data")
    tc() {
        if [[ "${1:-} ${2:-} ${4:-} ${5:-} ${6:-} ${9:-}" == "qdisc replace pacingaws parent 7ffe:$fail_minor fq" &&
              ! -e "$work/failed" ]]; then
            touch "$work/failed"; return 2
        fi
        command tc "$@"
    }
    if pacing_prepare_and_apply pacingaws 51200; then
        echo 'Expected injected FQ conversion failure' >&2; exit 1
    fi
    unset -f tc
    rolled=$(tc -j -d qdisc show dev pacingaws)
    pacing_codel_layout "$rolled" >/dev/null
    jq -e --argjson old "$data" '
      [.[]|select(.parent!=null)|.options] as $now |
      [$old[]|select(.parent!=null)|.options] as $before |
      ($now|length)==($before|length) and
      all(range(0; $before|length); . as $i |
        all($before[$i]|to_entries[];
          if .key=="target" or .key=="interval" or .key=="ce_threshold" then
            ($now[$i][.key] - .value | fabs) <= 1
          else $now[$i][.key] == .value end))' <<< "$rolled" >/dev/null
    [[ ! -e "$PACING_CONFIG_FILE" ]]
    # Retry from the addressed mq left by rollback.
    pacing_locked pacing_prepare_and_apply pacingaws 51200
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingaws)") == 51200 ]]
    pacing_locked pacing_disable
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingaws)") == 4294967295 ]]
    # Simulated reboot: fresh automatic fq_codel leaves + persisted policy.
    tc qdisc del dev pacingaws root
    PACING_POLICY_FILE="$work/policy.json"
    printf '%s\n' '{"version":1,"iface":"pacingaws","rate":51200}' > "$PACING_POLICY_FILE"
    pacing_locked pacing_restore_boot
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingaws)") == 51200 ]]
    pacing_locked pacing_disable
fi

# Explicit nonzero mq + FQ leaf layout.
ip link add pacingmq numtxqueues 2 type veth peer name pacingpeer numtxqueues 2
ip link set pacingmq up
tc qdisc replace dev pacingmq root handle 1: mq
if [[ ${PACING_TEST_DEFAULT_CODEL:-0} == 1 ]]; then
    data=$(tc -j -d qdisc show dev pacingmq)
    pacing_codel_layout "$data" >/dev/null
    [[ $(jq '[.[]|select(.parent!=null)]|length' <<< "$data") == 2 ]]
    tc() {
        if [[ "${1:-} ${2:-} ${4:-} ${5:-} ${6:-} ${9:-}" == 'qdisc replace pacingmq parent 1:2 fq' &&
              ! -e "$work/failed-second" ]]; then
            touch "$work/failed-second"; return 2
        fi
        command tc "$@"
    }
    if pacing_prepare_and_apply pacingmq 51200; then
        echo 'Expected second-leaf conversion failure' >&2; exit 1
    fi
    unset -f tc
    pacing_codel_layout "$(tc -j -d qdisc show dev pacingmq)" >/dev/null
    pacing_locked pacing_prepare_and_apply pacingmq 51200
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingmq)") == 51200 ]]
    pacing_locked pacing_disable
fi
# A normal mq root (outside the migration's 7fxx range) also has zero-handle
# automatic leaves. Exercise option 1 before explicitly configuring the leaves.
if [[ ${PACING_TEST_DEFAULT_FQ:-0} == 1 ]]; then
    initial=$(pacing_read_layout pacingmq)
    jq -e 'all(.targets[]; .handle == "0:")' <<< "$initial" >/dev/null
    # One leaf completed and one still zero: resume without replacing leaf 1.
    tc qdisc replace dev pacingmq parent 1:1 handle 7001: fq limit 2345 flow_limit 67
    pacing_locked pacing_prepare_and_apply pacingmq 102400
    [[ $(pacing_layout_rate "$(pacing_read_layout pacingmq)") == 102400 ]]
    tc -j qdisc show dev pacingmq | jq -e 'any(.[];
        .parent == "1:1" and .handle == "7001:" and .options.limit == 2345)' >/dev/null
    pacing_locked pacing_disable
fi
tc qdisc replace dev pacingmq parent 1:1 handle 7001: fq limit 2345 flow_limit 67
tc qdisc replace dev pacingmq parent 1:2 handle 7002: fq limit 2345 flow_limit 67
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
