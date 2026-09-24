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
