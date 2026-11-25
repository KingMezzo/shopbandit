import pathlib
import runpy
import unittest

validate = runpy.run_path(str(pathlib.Path(__file__).resolve().parents[1] / 'check-release-version.py'))['validate']


class ReleaseVersionTests(unittest.TestCase):
    def test_stable(self):
        self.assertEqual(validate('v1.1.0', 'version: 1.1.0+6\n'), ('1.1.0', False))

    def test_prereleases(self):
        for phase in ('alpha', 'beta', 'rc'):
            with self.subTest(phase=phase):
                self.assertEqual(validate(f'v1.1.0-{phase}.1', 'version: 1.1.0+6\n'), (f'1.1.0-{phase}.1', True))

    def test_exact_prerelease_pubspec(self):
        self.assertEqual(validate('v1.1.0-rc.1', 'version: 1.1.0-rc.1+6\n'), ('1.1.0-rc.1', True))

    def test_wrong_version(self):
        for tag in ('v1.0.4', 'v1.2.0-rc.1', 'v1.2.0'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                validate(tag, 'version: 1.1.0+6\n')

    def test_invalid_tags(self):
        for tag in ('vlatest', 'v1.1', 'v01.1.0', 'v1.1.0-rc.0', 'v1.1.0-rc.1;echo unsafe', '1.1.0'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                validate(tag, 'version: 1.1.0+6\n')

    def test_image_tag_must_match(self):
        with self.assertRaises(ValueError):
            validate('v1.1.0-rc.1', 'version: 1.1.0+6\n', '1.1.0')

    def test_build_number_required(self):
        with self.assertRaises(ValueError):
            validate('v1.1.0', 'version: 1.1.0\n')
