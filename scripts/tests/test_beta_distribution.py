"""Exercise the release/Pages boundary without publishing or downloading APKs."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


beta = load_module('beta_release', 'scripts/beta_release.py')
website = load_module('website_build', 'site/build.py')
VERSION = '0.1.0-beta.73'
NAME = f'camereon-beta-{VERSION}-arm64.apk'
COMMIT = 'a' * 40


def release(number, name=None):
    version = f'0.1.0-beta.{number}'
    name = name or f'camereon-beta-{version}-arm64.apk'
    prefix = f'https://github.com/camereon-dev/camereon/releases/download/v{version}/'
    return {
        'tag_name': f'v{version}', 'draft': False, 'prerelease': True,
        'published_at': f'2026-10-{number:02d}T00:00:00Z',
        'assets': [
            {'name': filename, 'state': 'uploaded', 'size': 60_000_000,
             'browser_download_url': prefix + filename}
            for filename in (name, name + '.sha256')
        ],
    }


class DistributionTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        old_cwd = Path.cwd()
        os.chdir(temporary.name)
        self.addCleanup(os.chdir, old_cwd)
        Path('pubspec.yaml').write_text('version: 0.1.0+1\n')
        Path('dist').mkdir()
        Path('dist/camereon-demo.apk').write_bytes(b'APK fixture')
        self.cert = b'synthetic signing certificate'
        env = {
            'GITHUB_RUN_NUMBER': '73', 'GITHUB_SHA': COMMIT,
            'CAMEREON_BETA_CERT_SHA256': hashlib.sha256(self.cert).hexdigest(),
            'GITHUB_REF': 'refs/heads/main', 'GITHUB_EVENT_NAME': 'push',
            'GITHUB_REPOSITORY': 'camereon-dev/camereon',
        }
        self.enterContext(patch.dict(os.environ, env))
        # Do not write to the calling runner's output/summary files.
        self.enterContext(patch.object(beta, 'output'))
        self.enterContext(patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': ''}))

    def package(self):
        pem = '-----BEGIN CERTIFICATE-----\n' + base64.b64encode(self.cert).decode() + '\n-----END CERTIFICATE-----'
        manifest = f"package: name='dev.camereon.camereon.demo' versionCode='73' versionName='{VERSION}'\nnative-code: 'arm64-v8a'\n"
        with patch.object(beta, 'android_tool', side_effect=lambda name: name), \
             patch.object(beta.subprocess, 'check_output', side_effect=[pem, manifest]), \
             contextlib.redirect_stdout(io.StringIO()):
            beta.package()
        return json.loads(Path('dist/beta/release.json').read_text())

    def test_package_and_publish_use_versioned_apk_and_checksum(self):
        metadata = self.package()
        self.assertEqual(metadata['apk_name'], NAME)
        apk = Path('dist/beta') / NAME
        checksum = apk.with_name(NAME + '.sha256')
        self.assertEqual(checksum.read_text(), f"{hashlib.sha256(apk.read_bytes()).hexdigest()}  {NAME}\n")
        with patch.object(beta, 'check_tag'), \
             patch.object(beta, 'api', side_effect=[None, {'draft': False, 'prerelease': True, 'html_url': 'https://example.test/release'}]), \
             patch.object(beta.subprocess, 'run') as run, \
             contextlib.redirect_stdout(io.StringIO()):
            beta.publish()
        upload = next(c.args[0] for c in run.call_args_list if c.args[0][:3] == ['gh', 'release', 'upload'])
        self.assertIn(str(apk), upload)
        self.assertIn(str(checksum), upload)
        self.assertIn(NAME, Path('dist/beta/release-notes.md').read_text())

    def test_publish_rejects_tampered_filename_before_network(self):
        metadata = self.package()
        metadata['apk_name'] = 'camereon-beta-arm64.apk'
        Path('dist/beta/release.json').write_text(json.dumps(metadata))
        with patch.object(beta, 'api') as api, self.assertRaisesRegex(ValueError, 'APK name'):
            beta.publish()
        api.assert_not_called()

    def test_publish_rejects_checksum_for_another_filename(self):
        self.package()
        (Path('dist/beta') / (NAME + '.sha256')).write_text('0' * 64 + '  old.apk\n')
        with patch.object(beta, 'api') as api, self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            beta.publish()
        api.assert_not_called()

    def test_publish_does_not_allow_prs(self):
        with patch.dict(os.environ, {'GITHUB_EVENT_NAME': 'pull_request'}), \
             self.assertRaisesRegex(ValueError, 'only be published from main'):
            beta.publish()


class PagesTest(unittest.TestCase):
    def metadata(self, releases):
        with patch.object(website, 'urlopen', return_value=io.BytesIO(json.dumps(releases).encode())):
            return website.release_metadata(False)

    def test_pages_prefers_newest_complete_versioned_release(self):
        old = release(20, 'camereon-beta-arm64.apk')
        new = release(27)
        result = self.metadata([old, new])
        self.assertEqual(result['version'], '0.1.0-beta.27')
        self.assertTrue(result['apk_url'].endswith('camereon-beta-0.1.0-beta.27-arm64.apk'))
        self.assertEqual(result['checksum_url'], result['apk_url'] + '.sha256')

    def test_pages_keeps_legacy_release_downloadable(self):
        result = self.metadata([release(20, 'camereon-beta-arm64.apk')])
        self.assertTrue(result['apk_url'].endswith('/camereon-beta-arm64.apk'))

    def test_incomplete_new_release_keeps_previous_download(self):
        new = release(27)
        new['assets'].pop()
        self.assertEqual(self.metadata([release(20), new])['version'], '0.1.0-beta.20')

    def test_name_must_match_release_version(self):
        with self.assertRaisesRegex(RuntimeError, 'No published beta'):
            self.metadata([release(27, 'camereon-beta-0.1.0-beta.26-arm64.apk')])

    def test_pages_rejects_unexpected_download_host(self):
        item = release(27)
        item['assets'][0]['browser_download_url'] = 'https://example.test/file.apk'
        with self.assertRaisesRegex(ValueError, 'download URL'):
            self.metadata([item])


if __name__ == '__main__':
    unittest.main()
