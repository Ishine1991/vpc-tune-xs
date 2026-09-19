"""AWS mq + fq_codel regression; tc mutations are isolated in a JSON fixture."""
import json
import unittest

import test_pacing as support


class CodelTests(unittest.TestCase):
    run_shell = support.PacingTests.run_shell
    ok = support.PacingTests.ok
    write_kernel = support.PacingTests.write_kernel

    def setUp(self):
        support.PacingTests.setUp(self)
        self.original = [
            {'kind': 'mq', 'handle': '0:', 'root': True, 'options': {}},
            *[{'kind': 'fq_codel', 'handle': '0:', 'parent': f':{i}',
               'options': {'limit': 10240, 'flows': 1024, 'quantum': 1514,
                           'target': 4999, 'interval': 99999,
                           'memory_limit': 33554432, 'ecn': True, 'drop_batch': 64}}
              for i in (2, 1)],
        ]
        self.state.write_text(json.dumps({'eth0': self.original}))

    def setup_tc(self, extra=''):
        return extra + r'''
cp "$KERNEL" "$KERNEL.original"
tc() {
    printf '%s\n' "$*" >> "$EVENTS"
    if [[ "$1" == -j ]]; then
        if [[ "$2" == filter ]]; then echo "${FILTERS:-[]}"; return; fi
        jq -c '.eth0' "$KERNEL"; return
    fi
    [[ "$1" == qdisc && "$4" == eth0 ]] || return 99
    if [[ "$2 $5" == 'replace root' ]]; then
        jq --arg h "$7" '.eth0 |= map(if .root then .handle=$h
          else .parent=($h + (.parent|split(":")|last)) end)' "$KERNEL" > "$KERNEL.tmp"
    elif [[ "$2 $5" == 'replace parent' ]]; then
        if [[ "${FAIL_LEAF:-}" == "$6" && "$9" == fq && ! -f "$KERNEL.failed" ]]; then
            touch "$KERNEL.failed"; return 2
        fi
        jq --arg p "$6" --arg h "$8" --arg kind "$9" --slurpfile orig "$KERNEL.original" '
          .eth0 |= map(if .parent==$p then .handle=$h | .kind=$kind |
            .options=(if $kind=="fq" then {pacing:true,limit:10000}
              else [$orig[0].eth0[]|select(.parent != null and
                (.parent|split(":")|last)==($p|split(":")|last))|.options][0] end)
            else . end)' "$KERNEL" > "$KERNEL.tmp"
    elif [[ "$2 $5" == 'change parent' ]]; then
        local token=${!#} rate
        rate=${token%bit}
        jq --arg p "$6" --argjson rate "$((rate / 8))" \
          '.eth0 |= map(if .parent==$p then .options.maxrate=$rate else . end)' \
          "$KERNEL" > "$KERNEL.tmp"
    else
        return 99
    fi
    mv "$KERNEL.tmp" "$KERNEL"
}
'''

    def leaves(self):
        return [q for q in json.loads(self.state.read_text())['eth0'] if 'parent' in q]

    def test_aws_apply_modify_disable_preserves_mq(self):
        self.ok('pacing_prepare_and_apply eth0 51200; pacing_apply_rate eth0 102400; pacing_disable',
                self.setup_tc())
        self.assertTrue(all(q['kind'] == 'fq' and q['options']['maxrate'] == 4294967295
                            for q in self.leaves()))
        self.assertNotIn('qdisc del', self.events.read_text())
        self.assertTrue(list(self.base.glob('config.migration-*')))

    def test_aws_boot_restore_converts_codel(self):
        (self.base / 'policy.json').write_text(json.dumps(
            {'version': 1, 'iface': 'eth0', 'rate': 51200}))
        self.ok('pacing_restore_boot', self.setup_tc())
        self.assertTrue(all(q['kind'] == 'fq' and q['options']['maxrate'] == 51200
                            for q in self.leaves()))

    def test_failed_second_leaf_rolls_back_both_original_options(self):
        proc = self.run_shell('pacing_prepare_and_apply eth0 51200',
                              self.setup_tc('FAIL_LEAF=7ffe:2\n'))
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue(all(q['kind'] == 'fq_codel' and q['options'] == self.original[1]['options']
                            for q in self.leaves()))
        self.assertFalse(self.config.exists())
        self.assertNotIn('qdisc change', self.events.read_text())
        # Retry the rolled-back addressed mq without replacing its root again.
        self.ok('pacing_prepare_and_apply eth0 51200', self.setup_tc())
        self.assertTrue(all(q['kind'] == 'fq' for q in self.leaves()))

    def test_filters_are_rejected_before_changes(self):
        proc = self.run_shell('pacing_prepare_and_apply eth0 51200',
                              self.setup_tc('FILTERS=\'[{}]\'\n'))
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn('qdisc replace', self.events.read_text())

    def test_unknown_options_and_mixed_queues_are_not_overwritten(self):
        for change in ('unknown', 'mixed', 'state'):
            with self.subTest(change=change):
                data = json.loads(json.dumps(self.original))
                if change == 'unknown':
                    data[1]['options']['new_option'] = 1
                elif change == 'mixed':
                    data[1]['kind'] = 'cake'
                else:
                    self.config.write_text('{broken')
                self.state.write_text(json.dumps({'eth0': data}))
                proc = self.run_shell('pacing_prepare_and_apply eth0 51200', self.setup_tc())
                self.assertNotEqual(proc.returncode, 0)
                self.assertNotIn('qdisc replace', self.events.read_text())

    def test_codel_time_arguments_are_microseconds(self):
        options = json.dumps(self.original[1]['options'])
        proc = self.ok("pacing_codel_args '" + options + "'")
        self.assertIn('target\n4999us\ninterval\n99999us', proc.stdout)
        self.assertIn('ecn\n', proc.stdout)


if __name__ == '__main__':
    unittest.main()
