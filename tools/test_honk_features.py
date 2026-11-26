import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MENU = (ROOT / "src/HonkMenuOverlay.mm").read_text()
HELPER = (ROOT / "src/jump_helper.S").read_text()


class HonkMenuPortTests(unittest.TestCase):
    def test_native_feature_state_bounds_and_dispatch(self):
        with tempfile.TemporaryDirectory(prefix="honk-state-test-") as temp:
            executable = Path(temp) / "state-test"
            subprocess.run(["c++", "-std=c++17", "-O2", "-pthread",
                            str(ROOT / "tools/test_honk_feature_state.cpp"), "-o", str(executable)],
                           check=True)
            subprocess.run([str(executable)], check=True)

    def test_menu_is_pass_through_and_multitouch_capable(self):
        self.assertIn("@implementation HonkPassthroughView", MENU)
        self.assertIn("return hit == self ? nil : hit", MENU)
        self.assertIn("gHonkRoot.multipleTouchEnabled = YES", MENU)
        self.assertIn("gHonkRoot.exclusiveTouch = NO", MENU)
        self.assertIn("gHonkPanel.multipleTouchEnabled = YES", MENU)

    def test_only_supported_categories_present_functional_controls(self):
        for title in ("Move", "Teleport", "Camera", "Goose/NPC", "World", "Experimental"):
            self.assertIn(f'@"{title}"', MENU)
        for control in ("Save goose position", "Restore saved position", "Horizontal speed",
                        "Jump impulse", "Starting area", "Geesus clip"):
            self.assertIn(control, MENU)
        self.assertIn("Unavailable in this build", MENU)
        self.assertIn("safe goose-collider enumeration and restoration are not yet verified", MENU)

    def test_ui_dispatches_commands_without_calling_unity(self):
        self.assertIn("HonkFeatures::publishCommand(gHonkState, HonkFeatures::kCommandSavePosition)", MENU)
        self.assertIn("HonkFeatures::publishCommand(gHonkState, HonkFeatures::kCommandRestorePosition)", MENU)
        self.assertIn("HonkFeatures::publishTeleport(gHonkState, p.x, p.y, p.z)", MENU)
        self.assertNotIn("Transform.set_position", MENU)
        self.assertNotIn("GameObject.Find", MENU)

    def test_physics_dispatch_uses_verified_rigidbody_methods(self):
        import sys
        sys.path.insert(0, str(ROOT / "tools"))
        import build_ipa
        expected = {
            "goose_reloc_speed_get_velocity": 0x101E15850,
            "goose_reloc_speed_set_velocity": 0x101E158FC,
            "goose_reloc_get_position": 0x101E16108,
            "goose_reloc_move_position": 0x101E16454,
            "goose_reloc_teleport_clear_velocity": 0x101E158FC,
        }
        for symbol, va in expected.items():
            self.assertEqual(build_ipa.RELOCS[symbol][1], va)
            self.assertIn(symbol + ":", HELPER)
        self.assertIn("stlr    wzr, [x10]", HELPER)
        self.assertIn("b.le    .Lafter_command", HELPER)
        self.assertIn("Rigidbody.MovePosition", HELPER)

    def test_teleport_guard_and_speed_multiplier_are_in_physics_helper(self):
        self.assertIn("HONK_SPEED_FACTOR_OFFSET", HELPER)
        self.assertIn("HONK_TARGET_X_OFFSET", HELPER)
        self.assertIn("HONK_SAVED_VALID_OFFSET", HELPER)
        self.assertIn("scvtf   s3, w10", HELPER)
        self.assertIn("fabs    s4, s0", HELPER)
        self.assertIn("fadd    s1, s1, s3", HELPER)


if __name__ == "__main__":
    unittest.main(verbosity=2)
