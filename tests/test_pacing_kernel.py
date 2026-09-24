"""Kernel selection safety tests. GRUB files/tools and reboot are isolated fakes."""
import unittest

import test_pacing as support


class KernelWizardTests(unittest.TestCase):
    run_shell = support.PacingTests.run_shell
    ok = support.PacingTests.ok
    write_kernel = support.PacingTests.write_kernel

    def setUp(self):
        support.PacingTests.setUp(self)
        self.grub = self.base / 'grub'
        self.grub.mkdir()
        self.env = self.grub / 'grubenv'
        self.env.write_text('saved_entry=original\n')
        self.cfg = self.grub / 'grub.cfg'
        self.cfg.write_text('''if [ "${next_entry}" ]; then
  set default="${next_entry}"
  set next_entry=
  save_env next_entry
fi
submenu 'Advanced options for Debian GNU/Linux' $menuentry_id_option 'gnulinux-advanced-abcd-1234' {
    menuentry 'Debian GNU/Linux, with Linux 5.10.0-test' $menuentry_id_option 'gnulinux-5.10.0-test-advanced-abcd-1234' {
    }
    menuentry 'Debian GNU/Linux, with Linux 5.10.0-test (recovery mode)' $menuentry_id_option 'gnulinux-5.10.0-test-recovery-abcd-1234' {
    }
}
''')
        module = self.base / 'module.sh'
        module.write_text(module.read_text(encoding='utf-8').replace(
            '/boot/grub', support.shell_path(self.grub)), encoding='utf-8', newline='\n')
        self.setup = f'''
TEST_ENV='{support.shell_path(self.env)}'
pacing_ifb_kernel_versions() {{ echo 5.10.0-test; }}
findmnt() {{
    case "$*" in *SOURCE*) echo /dev/test;; *FSTYPE*) echo ext4;; *) return 1;; esac
}}
lsblk() {{ printf 'part\ndisk\n'; }}
pacing_grub_env() {{
    case "$1" in
        list) command cat "$TEST_ENV";;
        unset) echo unset >> "$EVENTS"; printf 'saved_entry=original\n' > "$TEST_ENV";;
        *) return 99;;
    esac
}}
pacing_kernel_tool() {{
    case "$1" in
        grub-script-check) return 0;;
        grub-reboot)
            echo stage >> "$EVENTS"
            [[ "${{STAGE_FAIL:-0}}" != 1 ]] || return 1
            printf 'saved_entry=original\nnext_entry=%s\n' "${{BAD_ENTRY:-$3}}" > "$TEST_ENV";;
        reboot) echo reboot >> "$EVENTS";;
        *) return 99;;
    esac
}}
'''

    def events_text(self):
        return self.events.read_text() if self.events.exists() else ''

    def prompt_setup(self):
        return self.setup + '\npacing_kernel_can_prompt() { return 0; }'

    def test_grub_parser_selects_submenu_id_not_recovery(self):
        result = self.ok('pacing_grub_entry 5.10.0-test')
        self.assertEqual(result.stdout.strip(),
                         'gnulinux-advanced-abcd-1234>gnulinux-5.10.0-test-advanced-abcd-1234')
        self.assertNotEqual(self.run_shell('pacing_grub_entry no-such-kernel').returncode, 0)
        self.cfg.write_text(self.cfg.read_text() * 2)
        self.assertNotEqual(self.run_shell('pacing_grub_entry 5.10.0-test').returncode, 0)

    def test_noninteractive_never_prompts_or_changes_boot(self):
        self.assertNotEqual(self.run_shell('pacing_kernel_wizard', self.setup).returncode, 0)
        self.assertEqual(self.events_text(), '')

    def test_cancel_at_selection_or_confirmation_leaves_boot_unchanged(self):
        for answers in ('0', '', '999', '1\\nn', '1'):
            self.run_shell("pacing_kernel_wizard <<< $'" + answers + "'", self.prompt_setup())
            self.assertEqual(self.events_text(), '')
            self.assertEqual(self.env.read_text(), 'saved_entry=original\n')

    def test_schedule_only_requires_confirmation_and_makes_backup(self):
        self.ok("pacing_kernel_wizard <<< $'1\\ny\\nn'", self.prompt_setup())
        self.assertEqual(self.events_text(), 'stage\n')
        self.assertIn('next_entry=gnulinux-advanced-', self.env.read_text())
        backups = list(self.grub.glob('grubenv.pacing-backup.*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'saved_entry=original\n')

    def test_reboot_requires_second_explicit_yes(self):
        self.ok("pacing_kernel_wizard <<< $'1\\ny\\ny'", self.prompt_setup())
        self.assertEqual(self.events_text(), 'stage\nreboot\n')

    def test_failed_stage_or_bad_readback_never_reboots(self):
        for fault in ('STAGE_FAIL=1', 'BAD_ENTRY=external-choice'):
            self.env.write_text('saved_entry=original\n')
            self.assertNotEqual(self.run_shell(
                "pacing_kernel_wizard <<< $'1\\ny\\ny'",
                self.prompt_setup() + '\n' + fault).returncode, 0)
            self.assertNotIn('reboot', self.events_text())
        self.assertIn('next_entry=external-choice', self.env.read_text())

    def test_existing_next_entry_is_not_overwritten(self):
        self.env.write_text('next_entry=some-other-task\n')
        self.assertNotEqual(self.run_shell(
            "pacing_kernel_wizard <<< $'1\\ny\\ny'", self.prompt_setup()).returncode, 0)
        self.assertEqual(self.events_text(), '')
        self.assertEqual(self.env.read_text(), 'next_entry=some-other-task\n')

    def test_unsupported_storage_and_missing_next_entry_logic_rejected(self):
        for override in (
            'lsblk() { echo lvm; }',
            'findmnt() { echo btrfs; }',
        ):
            self.assertNotEqual(self.run_shell('pacing_grub_preflight', self.setup + '\n' + override).returncode, 0)
        self.cfg.write_text(self.cfg.read_text().replace('save_env next_entry', '# disabled'))
        self.assertNotEqual(self.run_shell('pacing_grub_preflight', self.setup).returncode, 0)
        self.assertEqual(self.events_text(), '')

    def test_ui_failure_does_not_apply_requested_rate(self):
        setup = self.prompt_setup() + '''
pacing_ifb_ready() { return 1; }
pacing_apply_persistent() { echo apply-rate >> "$EVENTS"; }
'''
        self.assertNotEqual(self.run_shell(
            "pacing_apply_interactive eth0 30720 <<< $'1\\ny\\nn'", setup).returncode, 0)
        self.assertEqual(self.events_text(), 'stage\n')

    def test_ui_ready_keeps_normal_apply_path(self):
        setup = self.setup + '''
pacing_ifb_ready() { return 0; }
pacing_apply_persistent() { [[ "$*" == 'eth0 30720 both' ]]; }
pacing_kernel_wizard() { echo unexpected-wizard >> "$EVENTS"; return 99; }
'''
        self.ok('pacing_apply_interactive eth0 30720', setup)
        self.assertEqual(self.events_text(), '')
