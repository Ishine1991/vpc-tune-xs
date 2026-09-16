"""Isolated shell control-flow tests. No real sysctl/tc/network changes.

Run: python -m unittest discover -s tests -v
Windows: set BASH_EXE and add jq.exe to PATH (Git Bash supported).
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
BASH = os.environ.get('BASH_EXE') or shutil.which('bash') or r'C:\Program Files\Git\bin\bash.exe'


def shell_path(path):
    path = Path(path).resolve()
    return '/' + path.drive[0].lower() + path.as_posix()[2:] if os.name == 'nt' else str(path)


class PacingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pacing-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        # Git Bash on Windows can inherit a restrictive ACL from Python's
        # 0700 temporary directory and then cannot create nested fixtures.
        if os.name == 'nt':
            os.chmod(self.base, 0o777)
        self.config = self.base / 'config'
        self.net = self.base / 'net'
        for iface in ('eth0', 'tun0', 'lo'):
            (self.net / iface).mkdir(parents=True)
        self.state = self.base / 'kernel.json'
        self.events = self.base / 'events'
        self.write_kernel()
        text = (REPO / 'net-tcp-tune.sh').read_text(encoding='utf-8')
        section = text[text.index('# TCP/FQ 每流限速：'):text.index('#启用BBR+cake')]
        section = section.replace('/sys/class/net', shell_path(self.net))
        (self.base / 'module.sh').write_text(section, encoding='utf-8', newline='\n')

    def write_kernel(self, kind='fq', rate=None, pacing=True):
        options = {'limit': 1234, 'flow_limit': 45, 'pacing': pacing}
        if rate is not None:
            options['maxrate'] = rate
        self.state.write_text(json.dumps({i: {'kind': kind, 'root': True,
            'handle': '8001:', 'options': dict(options)} for i in ('eth0', 'tun0')}))

    def run_shell(self, body, setup=''):
        # jq does actual JSON work. Only network and platform identity are stubbed.
        prefix = f"""
set -e
source '{shell_path(self.base / 'module.sh')}'
PACING_CONFIG_FILE='{shell_path(self.config)}'
PACING_SYSCTL_FILE='{shell_path(self.base / 'old.conf')}'
PACING_LOCK_FILE='{shell_path(self.base / 'lock')}'
PACING_POLICY_FILE='{shell_path(self.base / 'policy.json')}'
PACING_SERVICE_FILE='{shell_path(self.base / 'pacing.service')}'
PACING_INSTALLED_SCRIPT='{shell_path(self.base / 'installed/net-tcp-tune.sh')}'
PACING_STATE_DIR='{shell_path(self.base / 'states')}'
PACING_BOOT_RETRY_COUNT=2
PACING_BOOT_RETRY_SLEEP=0
KERNEL='{shell_path(self.state)}'
EVENTS='{shell_path(self.events)}'
pacing_boot_id() {{ echo boot-1; }}
pacing_ifindex() {{ echo 2; }}
break_end() {{ :; }}
sysctl() {{ echo 'FORBIDDEN sysctl' >> "$EVENTS"; return 99; }}
systemctl() {{ echo 'FORBIDDEN systemctl' >> "$EVENTS"; return 99; }}
tc() {{
    printf '%s\\n' "$*" >> "$EVENTS"
    if [[ "$1" == -j ]]; then
        [[ "$READ_FAIL" != 1 ]] || return 2
        if [[ "$2" == filter ]]; then echo '[]'; return; fi
        if [[ "$2" == -d ]]; then shift; fi
        jq -c --arg dev "$5" '[.[$dev]]' "$KERNEL"
    elif [[ "$1 $2" == 'qdisc replace' ]]; then
        [[ "$5 $6 $8" == 'root handle fq' ]] || return 2
        jq --arg dev "$4" --arg handle "$7" '.[$dev].handle=$handle' "$KERNEL" > "$KERNEL.tmp"
        mv "$KERNEL.tmp" "$KERNEL"
    elif [[ "$1 $2" == 'qdisc change' ]]; then
        [[ "$FAIL_BEFORE" != 1 ]] || return 2
        local token=${{!#}} dev=$4 rate
        rate=${{token%bit}}
        [[ $(jq -r --arg dev "$dev" '.[$dev].handle' "$KERNEL") != '0:' ]] || return 2
        if [[ "$6" == handle ]]; then
            [[ $(jq -r --arg dev "$dev" '.[$dev].handle' "$KERNEL") == "$7" ]] || return 2
        fi
        jq --arg dev "$dev" --argjson rate "$((rate / 8))" \\
           '.[$dev].options.maxrate=$rate' "$KERNEL" > "$KERNEL.tmp" || return 2
        mv "$KERNEL.tmp" "$KERNEL"
        [[ "$FAIL_AFTER" != 1 ]] || return 2
    else
        echo 'FORBIDDEN tc command' >> "$EVENTS"; return 99
    fi
}}
"""
        if os.name == 'nt':
            prefix = 'jq() { command jq.exe -b "$@"; }\n' + prefix
        proc = subprocess.run([BASH, '--noprofile', '--norc', '-s'],
                              input=prefix + setup + '\n' + body + '\n',
                              capture_output=True, text=True, encoding='utf-8', timeout=90)
        if self.events.exists():
            self.assertNotIn('FORBIDDEN', self.events.read_text())
        return proc

    def ok(self, body, setup=''):
        proc = self.run_shell(body, setup)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def rate(self, iface='eth0'):
        return json.loads(self.state.read_text())[iface]['options'].get('maxrate', 4294967295)

    def write_kernel_mq(self, second_kind='fq'):
        leaf_options = {'limit': 10000, 'flow_limit': 100, 'quantum': 3028}
        self.state.write_text(json.dumps({
            'eth0': [
                {'kind': 'mq', 'handle': '1:', 'root': True, 'options': {}},
                {'kind': 'fq', 'handle': '7002:', 'parent': '1:2',
                 'options': dict(leaf_options)},
                {'kind': second_kind, 'handle': '7001:', 'parent': '1:1',
                 'options': dict(leaf_options)},
            ],
            'tun0': [{'kind': 'fq', 'handle': '8001:', 'root': True,
                      'options': {'limit': 1234, 'flow_limit': 45, 'pacing': True}}],
        }))

    def mq_setup(self, fail_rate=None):
        failure = '''
        if [[ "$parent $rate" == '1:2 FAIL_RATE' && ! -e "$KERNEL.failed" ]]; then
            touch "$KERNEL.failed"; return 2
        fi
'''.replace('FAIL_RATE', str(fail_rate)) if fail_rate is not None else ''
        return f'''tc() {{
    printf '%s\\n' "$*" >> "$EVENTS"
    if [[ "$1" == -j ]]; then
        if [[ "$2" == -d ]]; then shift; fi
        jq -c --arg dev "$5" '.[$dev]' "$KERNEL"
    elif [[ "$1 $2" == 'qdisc replace' ]]; then
        [[ "$5 $7 $9" == 'parent handle fq' ]] || return 2
        jq --arg dev "$4" --arg parent "$6" --arg handle "$8" \\
          '.[$dev] |= map(if .parent == $parent then .handle=$handle else . end)' \\
          "$KERNEL" > "$KERNEL.tmp" || return 2
        mv "$KERNEL.tmp" "$KERNEL"
    elif [[ "$1 $2" == 'qdisc change' ]]; then
        local token=${{!#}} dev=$4 parent rate
        rate=${{token%bit}}
        if [[ "$5" == root ]]; then parent=root; else parent=$6; fi
        if [[ "$parent" != root ]]; then
            [[ "$7" == handle && "$8" != '0:' ]] || return 2
            jq -e --arg dev "$dev" --arg parent "$parent" --arg handle "$8" \\
              'any(.[$dev][]; .parent == $parent and .handle == $handle)' "$KERNEL" >/dev/null || return 2
        fi
        {failure}
        jq --arg dev "$dev" --arg parent "$parent" --argjson rate "$((rate / 8))" \\
          '.[$dev] |= map(if ((.root == true and $parent == "root") or .parent == $parent)
             then .options.maxrate=$rate else . end)' "$KERNEL" > "$KERNEL.tmp" || return 2
        mv "$KERNEL.tmp" "$KERNEL"
    else
        echo 'FORBIDDEN tc command' >> "$EVENTS"; return 99
    fi
}}
'''

    def mq_rates(self):
        return [item.get('options', {}).get('maxrate', 4294967295)
                for item in json.loads(self.state.read_text())['eth0']
                if item.get('parent')]

    def test_decimal_leading_zero_and_units(self):
        result = self.ok('pacing_parse_rate 08M; pacing_parse_rate 010; pacing_parse_rate 0000; pacing_parse_rate 3G; pacing_parse_rate 20K')
        self.assertEqual(result.stdout.splitlines(), ['8388608', '10485760', '0', '3221225472', '20480'])

    def test_migration_option_units(self):
        result = self.ok('pacing_fq_args \'{"limit":10000,"timer_slack":10000,"horizon":10000000,"low_rate_threshold":68750,"horizon_drop":null}\'')
        self.assertEqual(result.stdout.splitlines(), ['limit', '10000', 'timer_slack', '10000ns',
            'horizon', '10000000us', 'low_rate_threshold', '550000bit', 'horizon_drop'])
        result = self.ok('pacing_fq_args \'{"horizon_drop":true}\'')
        self.assertEqual(result.stdout.splitlines(), ['horizon_drop'])
        result = self.ok('pacing_fq_args \'{"bands":3,"priomap":[1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1],"weights":[589824,196608,65536]}\'')
        self.assertEqual(result.stdout.splitlines(), [
            'bands', '3', 'priomap',
            '1', '2', '2', '2', '1', '2', '0', '0',
            '1', '1', '1', '1', '1', '1', '1', '1',
            'weights', '589824', '196608', '65536',
        ])
        result = self.ok('PACING_FQ_SKIP_WEIGHTS=1 pacing_fq_args \'{"bands":3,"priomap":[1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1],"weights":[589824,196608,65536]}\'')
        self.assertNotIn('weights', result.stdout.splitlines())
        self.assertNotEqual(self.run_shell('pacing_fq_args \'{"bands":2}\'').returncode, 0)
        # iproute2 JSON uses "priomap " / "weights " with a trailing space.
        result = self.ok('PACING_FQ_SKIP_WEIGHTS=1 pacing_fq_args \'{"bands":3,"priomap ":[1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1],"weights ":[589824,196608,65536]}\'')
        self.assertEqual(result.stdout.splitlines()[:3], ['bands', '3', 'priomap'])
        self.ok('pacing_fq_options_match \'{"limit":10000,"weights":[1,2,3]}\' \'{"limit":10000}\'')
        self.assertNotEqual(self.run_shell('pacing_fq_options_match \'{"limit":10000}\' \'{"limit":9999}\'').returncode, 0)
        result = self.ok('pacing_fq_args \'{"quantum":"3028b","initial_quantum":"15140b","limit":"10000"}\'')
        lines = result.stdout.splitlines()
        pairs = dict(zip(lines[::2], lines[1::2]))
        self.assertEqual(pairs['quantum'], '3028')
        self.assertEqual(pairs['initial_quantum'], '15140')
        self.assertEqual(pairs['limit'], '10000')

    def test_require_addressable_rejects_zero_handles_on_migrated_mq(self):
        layout = self.base / 'layout.json'
        layout.write_text(
            '{"topology":"mq-fq","targets":[{"parent":"7ffe:1","handle":"0:","rate":4294967295}]}\n',
            encoding='utf-8', newline='\n')
        proc = self.run_shell(
            f'pacing_require_addressable "$(cat {shell_path(layout)})" && false')
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_zero_mq_requires_migration_before_writing_state(self):
        self.write_kernel_mq()
        data = json.loads(self.state.read_text())
        data['eth0'][0]['handle'] = '0:'
        for item in data['eth0'][1:]:
            item['parent'] = item['parent'][1:]
        self.state.write_text(json.dumps(data))
        proc = self.run_shell('pacing_apply_rate eth0 20480', self.mq_setup())
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.config.exists())
        self.assertNotIn('qdisc change', self.events.read_text())

    def test_real_vps_zero_mq_json_is_migratable(self):
        sample = json.dumps([
            {'kind': 'mq', 'handle': '0:', 'root': True, 'options': {}},
            {'kind': 'fq', 'handle': '0:', 'parent': ':2', 'options': {
                'limit': 10000, 'flow_limit': 100, 'buckets': 1024,
                'orphan_mask': 1023, 'quantum': 3028, 'initial_quantum': 15140,
                'low_rate_threshold': 68750, 'refill_delay': 40000,
                'timer_slack': 10000, 'horizon': 10000000, 'horizon_drop': None,
            }},
            {'kind': 'fq', 'handle': '0:', 'parent': ':1', 'dev': 'eth0',
             'options': {
                'limit': 10000, 'flow_limit': 100, 'buckets': 1024,
                'orphan_mask': 1023, 'quantum': 3028, 'initial_quantum': 15140,
                'low_rate_threshold': 68750, 'refill_delay': 40000,
                'timer_slack': 10000, 'horizon': 10000000, 'horizon_drop': None,
            }},
        ])
        self.ok("pacing_is_default_zero_mq '" + sample + "'")
        extra = json.loads(sample)
        extra[1]['options']['maxrate'] = 12345
        extra[0]['options'] = {'offloaded': False, 'hw': True}
        extra[1]['parent'] = '0:2'
        extra[2]['parent'] = '0:1'
        self.ok("pacing_is_default_zero_mq '" + json.dumps(extra) + "'")

    def test_newer_kernel_fq_bands_can_be_rebuilt(self):
        options = json.dumps({
            'limit': 10000, 'flow_limit': 100, 'buckets': 1024,
            'orphan_mask': 1023, 'quantum': 3028, 'initial_quantum': 15140,
            'low_rate_threshold': 68750, 'refill_delay': 40000,
            'timer_slack': 10000, 'horizon': 10000000, 'horizon_drop': None,
            'bands': 3,
            'priomap': [1, 2, 2, 2, 1, 2, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1],
        })
        proc = self.ok("pacing_fq_args '" + options + "'")
        self.assertIn('bands', proc.stdout.splitlines())
        self.assertIn('priomap', proc.stdout.splitlines())

    def test_migration_rejects_unknown_or_invalid_options(self):
        for options in ('{"new_option":1}', '{"limit":"oops"}', '{"pacing":null}'):
            with self.subTest(options=options):
                self.assertNotEqual(self.run_shell("pacing_fq_args '" + options + "'").returncode, 0)

    def test_reject_invalid_overflow_and_sentinel(self):
        self.ok('for r in 4G 9223372036854775807G -1 1.5M abc; do pacing_parse_rate "$r" && exit 1; done; exit 0')

    def test_empty_input_cancels(self):
        self.ok("pacing_input_rate <<< '' && exit 1; exit 0")
        self.assertFalse(self.config.exists())

    def test_pick_iface_by_number_skips_loopback(self):
        setup = '''
ip() {
    [[ "$1 $2" == "-br link" ]] || { echo 'FORBIDDEN ip' >> "$EVENTS"; return 99; }
    printf '%s\\n' 'lo UNKNOWN 00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>'
    printf '%s\\n' 'bond0 DOWN 00:00:00:00:00:00 <BROADCAST,MULTICAST>'
    printf '%s\\n' 'sit0 DOWN 00:00:00:00:00:00 <NOARP>'
    printf '%s\\n' 'eth0 UP 52:54:00:6b:c5:8c <BROADCAST,MULTICAST,UP,LOWER_UP>'
    printf '%s\\n' 'ens5@if2 UP 06:0c:3b:62:d4:cd <BROADCAST,MULTICAST,UP,LOWER_UP>'
}
'''
        proc = self.ok("pacing_pick_iface <<< 2; printf '%s\\n' \"$PACING_INPUT_IFACE\"", setup)
        self.assertEqual(proc.stdout.splitlines()[-1], 'ens5')
        self.assertIn('1. eth0', proc.stdout)
        self.assertIn('2. ens5', proc.stdout)
        self.assertNotIn(' lo', proc.stdout)
        self.assertNotIn('sit0', proc.stdout)
        self.assertNotIn('bond0', proc.stdout)
        self.assertNotEqual(self.run_shell('pacing_pick_iface <<< 9', setup).returncode, 0)
        self.assertNotEqual(self.run_shell("pacing_pick_iface <<< ''", setup).returncode, 0)

    def test_bare_number_is_mib(self):
        proc = self.ok("pacing_input_rate <<< 20; printf '%s\\n' \"$PACING_INPUT_RATE\"")
        self.assertEqual(proc.stdout.splitlines()[-1], '20971520')

    def test_kib_suffix_requires_confirmation(self):
        proc = self.run_shell("pacing_input_rate <<< $'20K\\nn' && exit 1; exit 0")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn('0.02 MiB/s', proc.stdout + proc.stderr)
        proc = self.ok("pacing_input_rate <<< $'20K\\ny'; printf '%s\\n' \"$PACING_INPUT_RATE\"")
        self.assertEqual(proc.stdout.splitlines()[-1], '20480')

    def test_apply_modify_disable_preserves_queue_and_other_iface(self):
        self.ok('pacing_apply_rate eth0 10485760; pacing_apply_rate eth0 20971520; pacing_disable')
        self.assertEqual(self.rate(), 4294967295)
        self.assertEqual(self.rate('tun0'), 4294967295)
        self.assertEqual(json.loads(self.state.read_text())['eth0']['options']['limit'], 1234)
        self.assertFalse(self.config.exists())

    def test_zero_uses_disable_no_1kbit(self):
        self.ok("pacing_apply_rate eth0 10485760; pacing_enable_all <<< 0", 'pacing_locked() { "$@"; }')
        self.assertEqual(self.rate(), 4294967295)
        self.assertNotIn('1kbit', self.events.read_text())

    def test_non_fq_and_nopacing_rejected(self):
        for kind, pacing in [('cake', True), ('mq', True), ('fq_codel', True), ('fq', False)]:
            with self.subTest(kind=kind, pacing=pacing):
                self.write_kernel(kind=kind, pacing=pacing)
                self.assertNotEqual(self.run_shell('pacing_apply_rate eth0 10485760').returncode, 0)
                self.assertFalse(self.config.exists())

    def test_default_handle_zero_is_migrated_before_change(self):
        self.write_kernel()
        data = json.loads(self.state.read_text())
        data['eth0']['handle'] = '0:'
        self.state.write_text(json.dumps(data))
        proc = self.run_shell('pacing_prepare_and_apply eth0 10485760')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.rate(), 10485760)
        self.assertTrue(self.config.exists())
        self.assertIn('qdisc replace dev eth0 root handle 7ffe: fq', self.events.read_text())
        self.assertIn('qdisc change dev eth0 root handle 7ffe: fq maxrate 83886080bit', self.events.read_text())
        self.assertNotIn('handle 0:', self.events.read_text())
        self.assertEqual(json.loads(self.state.read_text())['eth0']['options']['limit'], 1234)

    def test_mq_fq_leaves_apply_modify_disable_without_replacing_mq(self):
        self.write_kernel_mq()
        setup = self.mq_setup()
        self.ok('pacing_apply_rate eth0 10485760; pacing_apply_rate eth0 20971520; pacing_disable', setup)
        self.assertEqual(self.mq_rates(), [4294967295, 4294967295])
        data = json.loads(self.state.read_text())['eth0']
        self.assertEqual(data[0]['kind'], 'mq')
        self.assertEqual([x['options']['quantum'] for x in data[1:]], [3028, 3028])
        events = self.events.read_text()
        self.assertIn('qdisc change dev eth0 parent 1:1 handle 7001: fq maxrate', events)
        self.assertIn('qdisc change dev eth0 parent 1:2 handle 7002: fq maxrate', events)
        self.assertNotIn('qdisc change dev eth0 root', events)

    def test_reported_vps_default_root_fq_100k(self):
        data = json.loads(self.state.read_text())
        options = {'limit': 10000, 'flow_limit': 100, 'buckets': 1024,
                   'orphan_mask': 1023, 'quantum': 3028, 'initial_quantum': 15140,
                   'low_rate_threshold': 68750, 'refill_delay': 40000,
                   'timer_slack': 10000}
        data['eth0'] = {'kind': 'fq', 'handle': '0:', 'root': True,
                        'refcnt': 2, 'options': options}
        self.state.write_text(json.dumps(data))
        self.ok('pacing_prepare_and_apply eth0 "$(pacing_parse_rate 100K)"')
        self.assertEqual(self.rate(), 102400)
        events = self.events.read_text()
        self.assertIn('refill_delay 40000us', events)
        self.assertIn('timer_slack 10000ns', events)
        self.ok('pacing_disable')
        self.assertEqual(self.rate(), 4294967295)
        after = json.loads(self.state.read_text())['eth0']['options']
        for key, value in options.items():
            self.assertEqual(after[key], value)

    def test_mq_partial_failure_rolls_back_all_leaves(self):
        self.write_kernel_mq()
        proc = self.run_shell('pacing_apply_rate eth0 10485760', self.mq_setup(fail_rate=83886080))
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.mq_rates(), [4294967295, 4294967295])
        self.assertFalse(self.config.exists())
        changes = [line for line in self.events.read_text().splitlines() if 'qdisc change' in line]
        self.assertEqual(len(changes), 3)  # failed second leaf was never changed

    def test_zero_leaf_under_ordinary_mq_is_rejected_before_state_write(self):
        self.write_kernel_mq()
        data = json.loads(self.state.read_text())
        for leaf in data['eth0'][1:]:
            leaf['handle'] = '0:'
        self.state.write_text(json.dumps(data))
        proc = self.run_shell('pacing_apply_rate eth0 102400', self.mq_setup())
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.config.exists())
        self.assertNotIn('qdisc change', self.events.read_text())

    def test_option_one_migrates_ordinary_zero_mq_before_100k_apply(self):
        self.write_kernel_mq()
        data = json.loads(self.state.read_text())
        for leaf in data['eth0'][1:]:
            leaf['handle'] = '0:'
        self.state.write_text(json.dumps(data))
        setup = self.mq_setup() + '''
pacing_migrate_zero_mq() {
    echo migration >> "$EVENTS"
    jq '.eth0 |= map(if .parent == "1:1" then .handle="7001:"
        elif .parent == "1:2" then .handle="7002:" else . end)' "$KERNEL" > "$KERNEL.tmp"
    mv "$KERNEL.tmp" "$KERNEL"
}
'''
        self.ok('pacing_prepare_and_apply eth0 102400', setup)
        self.assertEqual(self.mq_rates(), [102400, 102400])
        events = self.events.read_text()
        self.assertLess(events.index('migration'), events.index('qdisc change'))

    def test_direct_zero_leaf_change_never_calls_tc(self):
        proc = self.run_shell('pacing_change_target eth0 1:1 0: 102400')
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.events.exists())

    def test_mq_disable_failure_restores_pre_disable_rates(self):
        self.write_kernel_mq()
        self.ok('pacing_apply_rate eth0 10485760', self.mq_setup())
        proc = self.run_shell('pacing_disable', self.mq_setup(fail_rate=34359738360))
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.mq_rates(), [10485760, 10485760])
        self.assertTrue(self.config.exists())

    def test_mq_rejects_mixed_leaf_qdiscs_without_changes(self):
        self.write_kernel_mq(second_kind='fq_codel')
        proc = self.run_shell('pacing_apply_rate eth0 10485760', self.mq_setup())
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.mq_rates(), [4294967295, 4294967295])
        self.assertNotIn('qdisc change', self.events.read_text())

    def test_mq_boot_restore_updates_every_fq_leaf(self):
        self.write_kernel_mq()
        (self.base / 'policy.json').write_text(
            json.dumps({'version': 1, 'iface': 'eth0', 'rate': 10485760}))
        self.ok('pacing_restore_boot', self.mq_setup())
        self.assertEqual(self.mq_rates(), [10485760, 10485760])
        saved = json.loads(self.config.read_text())
        self.assertEqual(saved['topology'], 'mq-fq')
        self.assertEqual(len(saved['targets']), 2)
        self.assertEqual(saved['phase'], 'active')

    def test_foreign_cap_rejected(self):
        self.write_kernel(rate=123456)
        self.assertNotEqual(self.run_shell('pacing_apply_rate eth0 10485760').returncode, 0)
        self.assertEqual(self.rate(), 123456)

    def test_tc_failure_before_change_needs_no_rollback(self):
        proc = self.run_shell('FAIL_BEFORE=1; pacing_apply_rate eth0 10485760')
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.config.exists())
        self.assertEqual(self.rate(), 4294967295)

    def test_initial_save_failure_makes_no_network_change(self):
        self.assertNotEqual(self.run_shell('pacing_apply_rate eth0 10485760',
                            'pacing_write_state() { return 1; }').returncode, 0)
        self.assertNotIn('qdisc change', self.events.read_text())

    def test_final_save_failure_rolls_back(self):
        setup = '''eval "$(declare -f pacing_write_state | sed '1s/pacing_write_state/original_write/')"
saves=0
pacing_write_state() { saves=$((saves+1)); [[ $saves != 2 ]] || return 1; original_write "$@"; }
'''
        self.assertNotEqual(self.run_shell('pacing_apply_rate eth0 10485760', setup).returncode, 0)
        self.assertEqual(self.rate(), 4294967295)
        self.assertFalse(self.config.exists())

    def test_disable_failure_does_not_claim_disabled(self):
        self.ok('pacing_apply_rate eth0 10485760')
        proc = self.run_shell('FAIL_BEFORE=1; pacing_disable')
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue(self.config.exists())
        self.assertEqual(self.rate(), 10485760)

    def test_external_change_refused(self):
        self.ok('pacing_apply_rate eth0 10485760')
        self.write_kernel(rate=100000)
        self.assertNotEqual(self.run_shell('pacing_disable').returncode, 0)
        self.assertEqual(self.rate(), 100000)

    def test_reboot_stale_record_not_applied(self):
        self.ok('pacing_apply_rate eth0 10485760')
        self.write_kernel()
        self.assertNotEqual(self.run_shell('pacing_disable', 'pacing_boot_id() { echo boot-2; }').returncode, 0)
        self.ok('pacing_forget_stale', 'pacing_boot_id() { echo boot-2; }')
        self.assertFalse(self.config.exists())

    def test_boot_restore_migrates_default_fq_handle(self):
        data = json.loads(self.state.read_text())
        data['eth0']['handle'] = '0:'
        self.state.write_text(json.dumps(data))
        (self.base / 'policy.json').write_text(
            json.dumps({'version': 1, 'iface': 'eth0', 'rate': 10485760}))
        self.ok('pacing_restore_boot')
        self.assertEqual(self.rate(), 10485760)
        self.assertNotIn('handle 0:', self.events.read_text())
        saved = json.loads(self.config.read_text())
        self.assertEqual(saved['boot'], 'boot-1')
        self.assertEqual(saved['phase'], 'active')

    def test_boot_restore_refuses_foreign_cap(self):
        self.write_kernel(rate=123456)
        (self.base / 'policy.json').write_text(
            json.dumps({'version': 1, 'iface': 'eth0', 'rate': 10485760}))
        self.assertNotEqual(self.run_shell('pacing_restore_boot').returncode, 0)
        self.assertEqual(self.rate(), 123456)
        self.assertFalse(self.config.exists())

    def test_autostart_install_and_remove(self):
        setup = '''systemctl() { printf '%s\n' "$*" >> "$EVENTS"; }
'''
        self.ok('pacing_enable_autostart eth0 10485760; pacing_read_policy >/dev/null', setup)
        policy = json.loads((self.base / 'policy.json').read_text())
        self.assertEqual(policy, {'version': 1, 'iface': 'eth0', 'rate': 10485760})
        self.assertIn('--restore-pacing', (self.base / 'pacing.service').read_text())
        self.assertTrue((self.base / 'installed/net-tcp-tune.sh').exists())
        self.ok('pacing_disable_autostart', setup)
        self.assertFalse((self.base / 'policy.json').exists())
        self.assertFalse((self.base / 'pacing.service').exists())

    def test_autostart_copies_running_script_without_download(self):
        setup = '''systemctl() { printf '%s\n' "$*" >> "$EVENTS"; }
'''
        self.ok('pacing_enable_autostart eth0 10485760', setup)
        self.assertTrue((self.base / 'installed/net-tcp-tune.sh').exists())
        self.assertIn('pacing_restore_boot', (self.base / 'installed/net-tcp-tune.sh').read_text(encoding='utf-8'))
        self.assertNotIn('raw.githubusercontent.com', self.events.read_text() if self.events.exists() else '')

    def test_autostart_rejects_pipe_source_when_download_fails(self):
        setup = '''
systemctl() { printf '%s\n' "$*" >> "$EVENTS"; }
PACING_SCRIPT_SOURCE=/dev/fd/63
curl() {
    printf '%s\\n' "$*" >> "$EVENTS"
    return 1
}
'''
        proc = self.run_shell('pacing_enable_autostart eth0 10485760', setup)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse((self.base / 'installed/net-tcp-tune.sh').exists())
        self.assertFalse((self.base / 'policy.json').exists())
        self.assertIn('raw.githubusercontent.com', self.events.read_text())

    def test_autostart_does_not_substitute_stale_script_when_download_fails(self):
        installed = self.base / 'installed' / 'net-tcp-tune.sh'
        installed.parent.mkdir(parents=True, exist_ok=True)
        installed.write_text('#!/bin/bash\npacing_restore_boot\n', encoding='utf-8')
        setup = '''
systemctl() { printf '%s\n' "$*" >> "$EVENTS"; }
PACING_SCRIPT_SOURCE=/dev/fd/63
curl() {
    printf '%s\\n' "$*" >> "$EVENTS"
    return 1
}
'''
        self.assertNotEqual(self.run_shell('pacing_apply_persistent eth0 102400', setup).returncode, 0)
        self.assertFalse((self.base / 'policy.json').exists())
        self.assertEqual(self.rate(), 4294967295)
        self.assertEqual(installed.read_text(encoding='utf-8'), '#!/bin/bash\npacing_restore_boot\n')
        self.assertIn('raw.githubusercontent.com', self.events.read_text())

    def test_autostart_pipe_source_downloads_published_script(self):
        installed = self.base / 'installed' / 'net-tcp-tune.sh'
        installed.parent.mkdir(parents=True, exist_ok=True)
        installed.write_text('#!/bin/bash\nSTALE\npacing_restore_boot\n', encoding='utf-8')
        setup = '''
systemctl() { printf '%s\n' "$*" >> "$EVENTS"; }
PACING_SCRIPT_SOURCE=/dev/fd/63
curl() {
    printf '%s\\n' "$*" >> "$EVENTS"
    local dest=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -o ]]; then dest="$2"; shift 2; continue; fi
        shift
    done
    [[ -n "$dest" ]] || return 1
    printf '%s\\n' '#!/bin/bash' 'pacing_restore_boot() { :; }' 'pacing_apply_persistent() { :; }' > "$dest"
}
'''
        self.ok('pacing_apply_persistent eth0 102400', setup)
        self.assertTrue(installed.exists())
        text = installed.read_text(encoding='utf-8')
        self.assertIn('pacing_restore_boot', text)
        self.assertIn('pacing_apply_persistent', text)
        self.assertNotIn('STALE', text)
        self.assertEqual(self.rate(), 102400)
        self.assertTrue((self.base / 'policy.json').exists())
        self.assertIn('raw.githubusercontent.com', self.events.read_text())

    def test_legacy_not_executed_and_blocks_enable(self):
        self.config.write_text('echo CONFIG_EXECUTED\n')
        proc = self.run_shell('pacing_apply_rate eth0 10485760')
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn('CONFIG_EXECUTED', proc.stdout)

    def test_old_sysctl_blocks_new_enable(self):
        (self.base / 'old.conf').write_text('old settings')
        self.assertNotEqual(self.run_shell('pacing_apply_rate eth0 10485760').returncode, 0)
        self.assertEqual(self.rate(), 4294967295)

    def test_legacy_zero_cleanup_archives_and_clears_matching_caps(self):
        self.config.write_text('# TCP 单连接限速配置 (由 net-tcp-tune.sh 自动管理)\nPACING_RATE_BPS=0\n', encoding='utf-8')
        (self.base / 'old.conf').write_text('# === 由 net-tcp-tune.sh 写入：FQ + BBR + 游戏延迟优化 ===\n', encoding='utf-8')
        self.write_kernel(rate=125)
        self.ok('pacing_legacy_cleanup <<< y')
        self.assertEqual(self.rate(), 4294967295)
        self.assertEqual(self.rate('tun0'), 4294967295)
        self.assertFalse(self.config.exists())
        self.assertFalse((self.base / 'old.conf').exists())
        self.assertEqual(len(list(self.base.glob('old.conf.disabled-*'))), 1)

    def test_status_checks_kernel_instead_of_saved_switch(self):
        self.ok('pacing_apply_rate eth0 10485760')
        self.write_kernel(rate=125)
        proc = self.ok('pacing_status_summary')
        self.assertIn('不一致', proc.stdout)

    def legacy_fixture(self):
        self.config.write_text('# TCP 单连接限速配置 (由 net-tcp-tune.sh 自动管理)\nPACING_RATE_BPS=0\n', encoding='utf-8')
        self.write_kernel(rate=125)

    def test_legacy_preflight_failure_changes_no_interface(self):
        self.legacy_fixture()
        setup = '''eval "$(declare -f tc | sed '1s/tc/original_tc/')"
tc() { [[ "$*" != '-j qdisc show dev tun0' ]] || return 2; original_tc "$@"; }
'''
        self.assertNotEqual(self.run_shell('pacing_legacy_cleanup <<< y', setup).returncode, 0)
        self.assertEqual(self.rate(), 125)
        self.assertTrue(self.config.exists())
        self.assertNotIn('qdisc change', self.events.read_text())

    def test_legacy_second_interface_failure_rolls_back_first(self):
        self.legacy_fixture()
        setup = '''eval "$(declare -f tc | sed '1s/tc/original_tc/')"
tc() {
    [[ "$1 $2 $4" != 'qdisc change tun0' || "${!#}" != 34359738360bit ]] || return 2
    original_tc "$@"
}
'''
        self.assertNotEqual(self.run_shell('pacing_legacy_cleanup <<< y', setup).returncode, 0)
        self.assertEqual(self.rate(), 125)
        self.assertEqual(self.rate('tun0'), 125)
        self.assertTrue(self.config.exists())

    def test_device_recreation_refuses_to_touch_new_device(self):
        self.ok('pacing_apply_rate eth0 10485760')
        self.write_kernel()
        self.assertNotEqual(self.run_shell('pacing_disable', 'pacing_ifindex() { echo 999; }').returncode, 0)
        self.assertEqual(self.rate(), 4294967295)

    def test_pending_record_can_recover_after_interruption(self):
        setup = '''eval "$(declare -f tc | sed '1s/tc/original_tc/')"
tc() {
    original_tc "$@"
    if [[ "$1 $2" == 'qdisc change' ]]; then exit 130; fi
}
'''
        self.assertNotEqual(self.run_shell('pacing_apply_rate eth0 10485760', setup).returncode, 0)
        self.assertEqual(self.rate(), 10485760)
        self.assertEqual(json.loads(self.config.read_text())['phase'], 'pending')
        self.ok('pacing_disable')
        self.assertEqual(self.rate(), 4294967295)

    def test_pending_record_refuses_external_rate_before_disable(self):
        setup = '''eval "$(declare -f tc | sed '1s/tc/original_tc/')"
tc() {
    original_tc "$@"
    if [[ "$1 $2" == 'qdisc change' ]]; then exit 130; fi
}
'''
        self.assertNotEqual(self.run_shell('pacing_apply_rate eth0 10485760', setup).returncode, 0)
        self.write_kernel(rate=100000)
        proc = self.run_shell('pacing_disable')
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.rate(), 100000)
        self.assertTrue(self.config.exists())

    def test_identity_checked_after_change(self):
        setup = '''eval "$(declare -f tc | sed '1s/tc/original_tc/')"
pacing_ifindex() { if [[ -f "$KERNEL.ifindex" ]]; then cat "$KERNEL.ifindex"; else echo 2; fi; }
tc() {
    original_tc "$@" || return $?
    if [[ "$1 $2" == 'qdisc change' ]]; then printf '999\\n' > "$KERNEL.ifindex"; fi
}
'''
        proc = self.run_shell('pacing_apply_rate eth0 10485760', setup)
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue(self.config.exists())

    def test_interrupted_modify_before_tc_can_disable(self):
        self.ok('pacing_apply_rate eth0 10485760')
        setup = '''eval "$(declare -f pacing_write_state | sed '1s/pacing_write_state/original_write/')"
pacing_write_state() { original_write "$@"; exit 130; }
'''
        self.assertNotEqual(self.run_shell('pacing_apply_rate eth0 20971520', setup).returncode, 0)
        self.assertEqual(self.rate(), 10485760)
        self.assertEqual(json.loads(self.config.read_text())['previous_rate'], 10485760)
        self.ok('pacing_disable')
        self.assertEqual(self.rate(), 4294967295)
        self.assertFalse(self.config.exists())

    def test_unreadable_or_empty_boot_id_preserves_record(self):
        self.ok('pacing_apply_rate eth0 10485760')
        for code in ('return 1', 'return 0'):
            with self.subTest(code=code):
                proc = self.run_shell('pacing_forget_stale', 'pacing_boot_id() { ' + code + '; }')
                self.assertNotEqual(proc.returncode, 0)
                self.assertTrue(self.config.exists())
                self.assertEqual(self.rate(), 10485760)

    def test_legacy_rebuilt_queue_is_not_overwritten(self):
        self.legacy_fixture()
        setup = '''eval "$(declare -f tc | sed '1s/tc/original_tc/')"
tc() {
    if [[ "$1 $2 $4" == 'qdisc change eth0' && ! -f "$KERNEL.rebuilt" ]]; then
        jq '.eth0.handle="9001:" | .eth0.options.maxrate=500000' "$KERNEL" > "$KERNEL.tmp"
        mv "$KERNEL.tmp" "$KERNEL"
        touch "$KERNEL.rebuilt"
    fi
    original_tc "$@"
}
'''
        proc = self.run_shell('pacing_legacy_cleanup <<< y', setup)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.rate(), 500000)
        self.assertTrue(self.config.exists())

    def test_legacy_mismatched_cap_preserves_files(self):
        self.legacy_fixture()
        self.write_kernel(rate=10485750)
        old_sysctl = self.base / 'old.conf'
        old_sysctl.write_text('# === 由 net-tcp-tune.sh 写入：FQ + BBR + 游戏延迟优化 ===\n', encoding='utf-8')
        proc = self.run_shell('pacing_legacy_cleanup <<< y')
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue(self.config.exists())
        self.assertTrue(old_sysctl.exists())
        self.assertEqual(self.rate(), 10485750)

    def test_second_iface_parks_first_state(self):
        self.ok('pacing_apply_rate eth0 10485760')
        self.ok('pacing_apply_rate tun0 20971520')
        self.assertEqual(self.rate(), 10485760)
        self.assertEqual(self.rate('tun0'), 20971520)
        parked = self.base / 'states' / 'eth0.json'
        self.assertTrue(parked.exists())
        self.assertEqual(json.loads(parked.read_text())['iface'], 'eth0')
        self.assertEqual(json.loads(self.config.read_text())['iface'], 'tun0')

    def test_policy_upgrades_to_two_ifaces(self):
        setup = '''systemctl() { printf '%s\n' "$*" >> "$EVENTS"; }
'''
        self.ok('pacing_enable_autostart eth0 10485760', setup)
        self.ok('pacing_enable_autostart tun0 20971520', setup)
        policy = json.loads((self.base / 'policy.json').read_text())
        self.assertEqual(policy['version'], 2)
        items = {item['iface']: item['rate'] for item in policy['items']}
        self.assertEqual(items, {'eth0': 10485760, 'tun0': 20971520})

    def test_migration_keeps_other_interface_record(self):
        self.ok('pacing_apply_rate tun0 10485760')
        data = json.loads(self.state.read_text())
        data['eth0']['handle'] = '0:'
        self.state.write_text(json.dumps(data))
        self.ok('pacing_prepare_and_apply eth0 102400')
        self.assertEqual(self.rate('tun0'), 10485760)
        self.assertEqual(self.rate(), 102400)
        self.assertTrue((self.base / 'states' / 'tun0.json').exists())

    def test_foreign_limit_blocks_zero_root_migration(self):
        self.write_kernel(rate=123456)
        data = json.loads(self.state.read_text())
        data['eth0']['handle'] = '0:'
        self.state.write_text(json.dumps(data))
        self.assertNotEqual(self.run_shell('pacing_prepare_and_apply eth0 102400').returncode, 0)
        self.assertNotIn('qdisc replace', self.events.read_text())
        self.assertEqual(self.rate(), 123456)

    def test_legacy_sysctl_blocks_migration_before_any_replace(self):
        data = json.loads(self.state.read_text())
        data['eth0']['handle'] = '0:'
        self.state.write_text(json.dumps(data))
        (self.base / 'old.conf').write_text('legacy')
        self.assertNotEqual(self.run_shell('pacing_prepare_and_apply eth0 102400').returncode, 0)
        self.assertNotIn('qdisc replace', self.events.read_text())

    def test_migration_rate_readback_is_not_ignored(self):
        self.assertNotEqual(self.run_shell(
            "pacing_fq_options_match '{\"limit\":10000,\"maxrate\":123}' '{\"limit\":10000}'").returncode, 0)

    def test_mixed_partial_mq_migration_keeps_completed_leaf(self):
        self.write_kernel_mq()
        data = json.loads(self.state.read_text())
        data['eth0'][1]['handle'] = '0:'
        self.state.write_text(json.dumps(data))
        self.ok('pacing_prepare_and_apply eth0 102400', self.mq_setup())
        events = self.events.read_text()
        self.assertIn('qdisc replace dev eth0 parent 1:2 handle 7002:', events)
        self.assertNotIn('qdisc replace dev eth0 parent 1:1', events)
        self.assertEqual(self.mq_rates(), [102400, 102400])

    def test_partial_migration_refuses_handle_collision(self):
        self.write_kernel_mq()
        data = json.loads(self.state.read_text())
        data['eth0'][1]['handle'] = '0:'
        data['eth0'][2]['handle'] = '7002:'
        self.state.write_text(json.dumps(data))
        self.assertNotEqual(self.run_shell('pacing_prepare_and_apply eth0 102400', self.mq_setup()).returncode, 0)
        self.assertNotIn('qdisc replace', self.events.read_text())

    def test_disable_selected_iface_keeps_other_rate_and_policy(self):
        setup = 'systemctl() { printf "%s\\n" "$*" >> "$EVENTS"; }'
        self.ok('pacing_apply_persistent eth0 102400; pacing_apply_persistent tun0 20971520', setup)
        self.ok('pacing_disable_iface eth0', setup)
        self.assertEqual(self.rate(), 4294967295)
        self.assertEqual(self.rate('tun0'), 20971520)
        policy = json.loads((self.base / 'policy.json').read_text())
        self.assertEqual(policy['items'], [{'iface': 'tun0', 'rate': 20971520}])
        self.assertTrue((self.base / 'pacing.service').exists())

    def test_invalid_policy_is_preserved_before_applying_rate(self):
        policy = self.base / 'policy.json'
        policy.write_text('{broken')
        proc = self.run_shell('pacing_apply_persistent eth0 102400')
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(policy.read_text(), '{broken')
        self.assertFalse(self.events.exists())

    def test_restore_script_rename_failure_does_not_apply_rate(self):
        proc = self.run_shell('pacing_apply_persistent eth0 102400', 'mv() { return 1; }')
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.events.exists())
        self.assertFalse(self.config.exists())

    def test_migrate_is_noop_when_root_fq_already_addressable(self):
        setup = '''
tc() {
    printf '%s\\n' "$*" >> "$EVENTS"
    if [[ "$1" == -j ]]; then
        jq -c --arg dev eth0 '[.[$dev]]' "$KERNEL"
    else
        echo 'FORBIDDEN tc command' >> "$EVENTS"; return 99
    fi
}
'''
        proc = self.ok('pacing_migrate_zero_mq eth0', setup)
        self.assertIn('无需迁移', proc.stdout)
        self.assertNotIn('qdisc replace', self.events.read_text())
        self.assertNotIn('qdisc del', self.events.read_text())

    def test_ensure_addressable_migrates_zero_or_partial_mq(self):
        setup = '''
pacing_read_layout() { printf '%s\\n' '{"topology":"mq-fq","targets":[{"parent":":1","handle":"0:","rate":4294967295}]}'; }
pacing_is_default_zero_mq() { return 0; }
pacing_is_partial_migrate() { return 1; }
pacing_migrate_zero_mq() { printf 'migrated %s\\n' "$1"; }
tc() { printf '%s\\n' "$*" >> "$EVENTS"; echo '[]'; }
'''
        proc = self.ok('pacing_ensure_addressable eth0', setup)
        self.assertIn('migrated eth0', proc.stdout)
        self.assertNotIn('qdisc del', self.events.read_text() if self.events.exists() else '')


if __name__ == '__main__':
    unittest.main()
