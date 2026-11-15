import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('widgets', pathlib.Path(__file__).resolve().parents[2] / 'scripts/check-widgets.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WidgetPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def ipa(self, name, host='com.google.music', widget=True, child=None, binary=True):
        path = pathlib.Path(self.temp.name) / name
        root = 'Payload/YouTubeMusic.app/'
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr(root + 'Info.plist', plistlib.dumps({'CFBundleIdentifier': host}))
            if widget:
                ext = root + 'PlugIns/Music.appex/'
                z.writestr(ext + 'Info.plist', plistlib.dumps({
                    'CFBundleIdentifier': child or host + '.widget', 'CFBundleExecutable': 'Widget',
                    'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}}))
                if binary:
                    z.writestr(ext + 'Widget', b'fixture')
        return path

    def test_preserves_widget_with_custom_host_id(self):
        self.assertEqual(len(module.check(self.ipa('in.ipa'), self.ipa('out.ipa', host='org.personal.music'))), 1)

    def test_rejects_removed_widget(self):
        with self.assertRaisesRegex(ValueError, 'No WidgetKit'):
            module.check(self.ipa('in.ipa'), self.ipa('out.ipa', widget=False))

    def test_rejects_missing_executable(self):
        with self.assertRaisesRegex(ValueError, 'executable missing'):
            module.widgets(self.ipa('bad.ipa', binary=False))

    def test_rejects_mismatched_extension_identity(self):
        with self.assertRaisesRegex(ValueError, 'child of host'):
            module.widgets(self.ipa('bad.ipa', child='com.other.widget'))


if __name__ == '__main__':
    unittest.main()
