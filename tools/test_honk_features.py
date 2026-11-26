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
        self.assertIn("Collision stays enabled; this is not noclip", MENU)
        self.assertIn("this build exposes no verified reversible Collider setter", MENU)
        for supported in ("Float / hold height", "Custom game speed", "Goose size",
                          "Follow camera distance", "Disable NPC shoo"):
            self.assertIn(supported, MENU)
        for key in ("HonkMenu.FloatEnabled", "HonkMenu.TimeScaleEnabled",
                    "HonkMenu.TimeScale", "HonkMenu.SizeFactor", "HonkMenu.CameraFactor",
                    "HonkMenu.DisableNpcShoo"):
            self.assertIn(key, MENU)

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
            "goose_reloc_hover_kinematic": 0x101E15DA8,
            "goose_reloc_hover_get_velocity": 0x101E15850,
            "goose_reloc_hover_set_velocity": 0x101E158FC,
            "goose_reloc_component_transform": 0x101DBA100,
            "goose_reloc_transform_get_scale": 0x101DEB834,
            "goose_reloc_transform_set_scale": 0x101DEB8E0,
            "goose_reloc_rate_get_time_scale": 0x101DE9FE0,
            "goose_reloc_set_time_scale": 0x101DEA040,
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

    def test_float_size_and_time_controls_are_game_thread_operations(self):
        for offset in ("HONK_HOVER_ENABLED_OFFSET", "HONK_TIME_SCALE_OFFSET",
                       "HONK_SIZE_FACTOR_OFFSET", "HONK_BASE_SCALE_X_OFFSET"):
            self.assertIn(offset, HELPER)
        self.assertIn(".Lrestore_time_scale", HELPER)
        self.assertIn("UnityEngine.Time.set_timeScale", HELPER)
        self.assertIn("Transform.set_localScale", HELPER)
        self.assertIn("Rigidbody.set_velocity", HELPER)

    def test_camera_and_npc_shoo_hooks_use_pinned_mappings(self):
        import sys
        sys.path.insert(0, str(ROOT / "tools"))
        import build_ipa
        self.assertEqual(build_ipa.SHOO_HOOK_VA, 0x10107D13C)
        self.assertEqual(build_ipa.SHOO_HOOK_ORIGINAL, 0xA9BE4FF4)
        self.assertEqual(build_ipa.SHOO_GUARD_VA, build_ipa.HELPER_VA + 0x1000)
        self.assertIn("Goose.gooseCameraHelper", HELPER)
        self.assertIn("GooseCameraHelper.distance", HELPER)
        self.assertIn("Body.shooReadiness.timeAllowedToShooAgain", HELPER)
        self.assertIn("goose_reloc_shoo_continue", HELPER)
        self.assertIn("str     wzr, [x22, #HONK_SCALE_CAPTURED_OFFSET]", HELPER)
        self.assertIn("str     wzr, [x22, #HONK_CAMERA_CAPTURED_OFFSET]", HELPER)


if __name__ == "__main__":
    unittest.main(verbosity=2)
