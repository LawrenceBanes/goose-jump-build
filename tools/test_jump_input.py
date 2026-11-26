import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = (ROOT / "src/JumpOverlay.mm").read_text()
HELPER = (ROOT / "src/jump_helper.S").read_text()


class JumpInputRegressionTests(unittest.TestCase):
    def test_multitouch_is_enabled_without_exclusive_touch(self):
        self.assertIn("view.multipleTouchEnabled = YES", OVERLAY)
        self.assertIn("view.exclusiveTouch = NO", OVERLAY)
        self.assertIn("gJumpButton.multipleTouchEnabled = YES", OVERLAY)
        self.assertIn("gJumpButton.exclusiveTouch = NO", OVERLAY)

    def test_overlay_hit_test_is_limited_to_button_shape(self):
        self.assertIn("- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event", OVERLAY)
        self.assertIn("bezierPathWithRoundedRect:self.bounds", OVERLAY)
        self.assertNotIn("UIScreen.mainScreen.bounds", OVERLAY)
        self.assertIn("[root addSubview:gJumpButton]", OVERLAY)

    def test_one_touch_down_enqueues_and_holding_does_not_repeat(self):
        self.assertIn("- (void)touchesBegan:", OVERLAY)
        self.assertIn("GooseJumpInput::enqueue(&gJumpData->pendingState, now)", OVERLAY)
        self.assertNotIn("UIControlEventTouchUpInside", OVERLAY)
        self.assertNotIn("repeat:YES", OVERLAY)
        self.assertNotIn("touchesMoved:", OVERLAY)

    def test_lifecycle_clears_queued_events(self):
        self.assertIn("UIApplicationWillResignActiveNotification", OVERLAY)
        self.assertIn("UIApplicationDidEnterBackgroundNotification", OVERLAY)
        self.assertIn("GooseJumpInput::clear(&gJumpData->pendingState)", OVERLAY)

    def test_canceled_touch_only_clears_button_presentation(self):
        cancel = OVERLAY.split("- (void)touchesCancelled:", 1)[1].split("@end", 1)[0]
        self.assertIn("[super touchesCancelled:touches withEvent:event]", cancel)
        self.assertNotIn("enqueue", cancel)

    def test_helper_consumes_queued_events_and_allows_air_jumps(self):
        self.assertIn(".Lqueue_retry:", HELPER)
        self.assertIn("sub     x11, x9, #1", HELPER)
        self.assertIn("fadd    s1, s1, s3", HELPER)
        self.assertNotIn("ground_check", HELPER.lower())

    def test_configured_impulse_is_named_and_increased(self):
        self.assertIn("#define GOOSE_JUMP_IMPULSE 2.5f", OVERLAY)
        self.assertIn('parser.add_argument("--impulse", type=float, default=2.5)',
                      (ROOT / "tools/build_components.py").read_text())

    def test_jump_sets_only_vertical_velocity_and_releases_cap_afterward(self):
        self.assertIn("str     s0, [sp, #0]", HELPER)
        self.assertIn("str     s2, [sp, #8]", HELPER)
        self.assertIn("str     s1, [x11, #0x18]", HELPER)
        self.assertIn(".Lrestore_cap:", HELPER)

    def test_native_event_queue_preserves_concurrent_rapid_taps(self):
        with tempfile.TemporaryDirectory(prefix="goose-jump-queue-test-") as temp:
            executable = Path(temp) / "queue-test"
            subprocess.run(["c++", "-std=c++17", "-O2", "-pthread",
                            str(ROOT / "tools/test_jump_queue.cpp"), "-o", str(executable)],
                           check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
