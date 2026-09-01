import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENTITLEMENTS = ROOT / "DynamicIsland" / "DynamicIsland.entitlements"
PROJECT = ROOT / "DynamicIsland.xcodeproj" / "project.pbxproj"


class PrivacyConfigurationTests(unittest.TestCase):
    def test_camera_capture_is_not_entitled(self):
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

        self.assertIsNone(entitlements.get("com.apple.security.device.camera"))

    def test_media_control_is_authorized_for_apple_events(self):
        project = PROJECT.read_text()
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

        apple_events = entitlements["com.apple.security.temporary-exception.apple-events"]
        self.assertNotIn("AUTOMATION_APPLE_EVENTS = NO;", project)
        self.assertIn("com.apple.Music", apple_events)
        self.assertNotIn("com.apple.Notes", apple_events)

    def test_automation_usage_text_names_media_apps(self):
        project = PROJECT.read_text()

        self.assertEqual(
            2,
            project.count(
                'INFOPLIST_KEY_NSAppleEventsUsageDescription = "Atoll uses AppleScripts to control Spotify and Apple Music.";'
            ),
        )

    def test_full_access_reminder_api_has_matching_usage_text(self):
        project = PROJECT.read_text()

        self.assertEqual(
            2,
            project.count("INFOPLIST_KEY_NSRemindersFullAccessUsageDescription ="),
        )


if __name__ == "__main__":
    unittest.main()
