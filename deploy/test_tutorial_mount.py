import unittest
from pathlib import Path


ROOT = Path(__file__).parent


class TutorialMountTest(unittest.TestCase):
    def test_main_compose_mounts_store_read_only_and_uses_file_key(self):
        text = (ROOT / 'compose.main.yml').read_text()
        self.assertIn('${TUTORIALS_HOST_DIR:?TUTORIALS_HOST_DIR must be set}:/srv/tutorials:ro', text)
        self.assertIn('TUTORIALS_DIR: /srv/tutorials', text)
        self.assertIn('TUTORIALS_SIGNING_SECRET_FILE: /run/secrets/tutorials-signing-key', text)
        self.assertIn('TUTORIALS_SIGNING_KEY_FILE:?TUTORIALS_SIGNING_KEY_FILE must be set', text)

    def test_preview_has_the_same_read_only_store_contract(self):
        text = (ROOT / 'compose.preview.yml').read_text()
        self.assertIn('${TUTORIALS_HOST_DIR:?TUTORIALS_HOST_DIR must be set}:/srv/tutorials:ro', text)
        self.assertIn('tutorials-signing-key:', text)

    def test_manager_keeps_key_out_of_environment_values(self):
        text = (ROOT / 'manage.py').read_text()
        self.assertIn('TUTORIALS_SIGNING_KEY_FILE', text)
        self.assertIn('ensure_secret', text)


if __name__ == '__main__':
    unittest.main()
