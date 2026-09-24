"""Duplex policy compatibility and strict ingress ownership checks."""
import json
import unittest

import test_pacing as support


class DuplexTests(unittest.TestCase):
    run_shell = support.PacingTests.run_shell
    ok = support.PacingTests.ok
    write_kernel = support.PacingTests.write_kernel

    def setUp(self):
        support.PacingTests.setUp(self)

    def ingress_journal(self, boot='old-boot'):
        directory = self.base / 'states' / 'ingress'
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / 'eth0.json'
        path.write_text(json.dumps({
            'version': 1, 'iface': 'eth0', 'ifindex': '2', 'ifb': 'ntifb2',
            'boot': boot, 'owner': f'net-tcp-tune:ingress:eth0:2:{boot}',
            'ifb_index': 3, 'rate': 1048576, 'phase': 'pending',
            'ingress_owned': False,
        }))
        return path

    def test_forget_stale_ingress_only_without_network_changes(self):
        path = self.ingress_journal()
        self.ok('pacing_forget_stale')
        self.assertFalse(path.exists())
        self.assertFalse(self.events.exists())

    def test_forget_validates_ingress_before_removing_egress(self):
        self.ok('pacing_apply_rate eth0 1048576')
        state = json.loads(self.config.read_text())
        state['boot'] = 'old-boot'
        self.config.write_text(json.dumps(state))
        path = self.ingress_journal('boot-1')
        self.assertNotEqual(self.run_shell('pacing_forget_stale').returncode, 0)
        self.assertTrue(self.config.exists())
        self.assertTrue(path.exists())
        path.write_text('broken')
        self.assertNotEqual(self.run_shell('pacing_forget_stale').returncode, 0)
        self.assertTrue(self.config.exists())
        self.ingress_journal()
        self.ok('pacing_forget_stale')
        self.assertFalse(self.config.exists())
        self.assertFalse(path.exists())

    def test_ambiguous_ingress_is_not_deleted_after_interruption(self):
        path = self.ingress_journal('boot-1')
        setup = '''
ip() { echo '[]'; }
tc() {
    if [[ "$1" != -j ]]; then echo 'UNSAFE mutation' >> "$EVENTS"; return 99; fi
    echo '[{"kind":"ingress","handle":"ffff:"}]'
}
'''
        self.assertNotEqual(self.run_shell('pacing_rx_disable eth0', setup).returncode, 0)
        self.assertTrue(path.exists())
        self.assertFalse(self.events.exists())

    def test_upgrading_one_iface_preserves_other_policy(self):
        setup = 'systemctl() { :; }'
        self.ok('pacing_enable_autostart eth0 1048576; pacing_enable_autostart tun0 2097152 both', setup)
        policy = json.loads((self.base / 'policy.json').read_text())
        self.assertEqual(policy['items'], [
            {'iface': 'eth0', 'rate': 1048576},
            {'iface': 'tun0', 'rate': 2097152, 'ingress': True},
        ])
        self.ok('pacing_enable_autostart eth0 3145728 both', setup)
        policy = json.loads((self.base / 'policy.json').read_text())
        self.assertTrue(all(item['ingress'] for item in policy['items']))

    def test_invalid_ingress_policy_rejected_before_network_mutation(self):
        (self.base / 'policy.json').write_text(json.dumps(
            {'version': 1, 'iface': 'eth0', 'rate': 1048576, 'ingress': 'true'}))
        self.assertNotEqual(self.run_shell('pacing_apply_persistent eth0 1048576 both').returncode, 0)
        self.assertFalse(self.events.exists())

    def test_single_iface_policy_retains_direction(self):
        (self.base / 'policy.json').write_text(json.dumps(
            {'version': 1, 'iface': 'eth0', 'rate': 1048576, 'ingress': True}))
        result = self.ok('pacing_policy_items')
        self.assertEqual(json.loads(result.stdout), [
            {'iface': 'eth0', 'rate': 1048576, 'ingress': True}])

    def test_foreign_or_extra_filter_is_never_owned(self):
        expected = [{
            'kind': 'matchall', 'protocol': 'all', 'pref': 49139, 'chain': 0,
            'options': {'handle': 1, 'actions': [{
                'kind': 'mirred', 'to_dev': 'ntifb2', 'direction': 'egress',
                'mirred_action': 'redirect'}]},
        }]
        self.ok("pacing_rx_filters_match '" + json.dumps(expected) + "' ntifb2")
        for bad in (
            expected + [{'kind': 'bpf', 'pref': 2}],
            [{**expected[0], 'chain': 1}],
            [{**expected[0], 'protocol': 'ip'}],
            [{**expected[0], 'options': {'handle': 1, 'actions': [
                *expected[0]['options']['actions'], {'kind': 'police'}]}}],
        ):
            with self.subTest(filters=bad):
                proc = self.run_shell("pacing_rx_filters_match '" + json.dumps(bad) + "' ntifb2")
                self.assertNotEqual(proc.returncode, 0)
