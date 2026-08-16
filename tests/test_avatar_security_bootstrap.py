import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ensure_avatar_security.ps1"


class AvatarSecurityBootstrapTest(unittest.TestCase):
    def run_script(self, data_root: Path) -> str:
        completed = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPT),
                "-DataRoot",
                str(data_root),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return completed.stdout.strip()

    def test_token_is_stable_per_install_and_distinct_between_installs(self):
        with tempfile.TemporaryDirectory() as temp:
            first_root = Path(temp) / "first"
            second_root = Path(temp) / "second"
            first = self.run_script(first_root)
            repeated = self.run_script(first_root)
            second = self.run_script(second_root)
            self.assertEqual(first, repeated)
            self.assertNotEqual(first, second)
            self.assertRegex(first, re.compile(r"^[A-Za-z0-9_-]{43}$"))
            token_file = first_root / "config" / "avatar-admin-token.txt"
            self.assertEqual(token_file.read_text(encoding="utf-8"), first)
            self.assertFalse(token_file.read_bytes().startswith(b"\xef\xbb\xbf"))


if __name__ == "__main__":
    unittest.main()
