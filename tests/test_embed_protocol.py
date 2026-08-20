import unittest
from pathlib import Path


EMBED = Path(__file__).resolve().parents[1] / "web" / "embed.html"


class EmbedProtocolTest(unittest.TestCase):
    def test_avatar_offer_and_parent_messages_are_present(self):
        source = EMBED.read_text(encoding="utf-8")
        for fragment in (
            "const avatarId =",
            "avatar: avatarId || undefined",
            "type: 'lt-session'",
            "type: 'lt-state'",
            "avatarId",
        ):
            self.assertIn(fragment, source)

    def test_explicit_stop_disables_retry_and_reports_completion(self):
        source = EMBED.read_text(encoding="utf-8")
        for fragment in (
            "let allowRetry = true",
            "event.data.type !== 'lt-stop'",
            "allowRetry = false",
            "type: 'lt-stopped'",
            "clearTimeout(retryTimer)",
        ):
            self.assertIn(fragment, source)

    def test_portrait_video_keeps_a_contained_foreground_over_blurred_fill(self):
        """Catch regressions that stretch a portrait avatar to viewport width."""
        source = EMBED.read_text(encoding="utf-8")
        for fragment in (
            '<video id="video-backdrop"',
            '#video-backdrop {',
            'object-fit: cover;',
            'filter: blur(',
            '#video {',
            'object-fit: contain;',
            "const stream = evt.streams[0];",
            "document.getElementById('video-backdrop').srcObject = stream;",
            "document.getElementById('video').srcObject = stream;",
        ):
            self.assertIn(fragment, source)


if __name__ == "__main__":
    unittest.main()
