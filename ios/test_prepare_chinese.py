import json
from pathlib import Path
import tempfile
import unittest

from prepare_chinese import FILES, MOD_ID, prepare

ARCHIVE = Path(__file__).resolve().parents[1] / 'build/wwhd-chinese-v1.0.2.zip'


class ChinesePackageTest(unittest.TestCase):
    def test_unverified_archive_cannot_create_output(self):
        with tempfile.TemporaryDirectory() as d:
            archive = Path(d) / 'modified.zip'
            archive.write_bytes(b'untrusted or incomplete download')
            output = Path(d) / 'mod'
            with self.assertRaisesRegex(ValueError, 'verified v1.0.2'):
                prepare(archive, output)
            self.assertFalse(output.exists())

    @unittest.skipUnless(ARCHIVE.is_file(), 'download the official release archive first')
    def test_official_resources_and_existing_destination_are_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            output = Path(d) / MOD_ID
            hashes = prepare(ARCHIVE, output)
            self.assertEqual(set(hashes), set(FILES))
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertEqual(manifest['kind'], 'content')
            self.assertEqual(manifest['id'], MOD_ID)
            before = {str(p.relative_to(output)): p.read_bytes() for p in output.rglob('*') if p.is_file()}
            self.assertFalse(any(name.endswith(('.rpx', '.rpl')) for name in before))
            with self.assertRaises(FileExistsError):
                prepare(ARCHIVE, output)
            after = {str(p.relative_to(output)): p.read_bytes() for p in output.rglob('*') if p.is_file()}
            self.assertEqual(before, after)


if __name__ == '__main__':
    unittest.main()
