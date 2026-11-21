#!/usr/bin/env python3
"""Package the project's v1.0.2 release as an existing content mod (no RPX changes)."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

SOURCE = 'https://github.com/wmltogether/ZLD-TWW-HD-Chinese-Localization-Project/releases/tag/v1.0.2'
ZIP_BYTES = 11480537
ZIP_SHA256 = '08d3fe17d2c3d9c60bc94d7ad03a0e5b0bf6224add22815f7683df779e992519'
MOD_ID = 'content.wwhd.zh-cn'
FILES = {
    'Common/Pack/permanent_2d_UsEnglish.pack': (13863630, '2112cb20489d70ffe7a9b269561cf9d3aa637bd9dd3ee2ada83ff827fd1ce235', b'SARC'),
    'Common/Layout/Title_00.szs': (114319, '1589bfe2c2ba93335a00d4b200d0ecfa997b20458b152ef70c241a0e5e654bd4', b'Yaz0'),
}


def prepare(archive, destination):
    if archive.stat().st_size != ZIP_BYTES or hashlib.sha256(archive.read_bytes()).hexdigest() != ZIP_SHA256:
        raise ValueError('archive does not match the verified v1.0.2 release')
    payload = {}
    with zipfile.ZipFile(archive) as z:
        for name, (size, expected_hash, magic) in FILES.items():
            data = z.read('release/content/' + name)
            if len(data) != size or not data.startswith(magic):
                raise ValueError('invalid resource: ' + name)
            if hashlib.sha256(data).hexdigest() != expected_hash:
                raise ValueError('resource checksum mismatch: ' + name)
            payload[name] = data
        readme = z.read('release/README.txt')
    destination.mkdir(parents=True, exist_ok=False)
    for name, data in payload.items():
        p = destination / 'content' / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    manifest = {
        'format_version': 1, 'id': MOD_ID, 'name': '风之杖 HD 简体中文',
        'version': '1.0.2', 'game_id': 'wwhd', 'kind': 'content',
        'author': 'wmltogether / HD 汉化项目参与者；原版：鼯鼠工作室、漫游汉化组',
        'description': 'Official project release: ' + SOURCE + '. Text/font pack and title artwork; keep the original game executable. Personal non-commercial use; see source README.',
        'minimum_manager_version': '1.5.0', 'content_dir': 'content',
    }
    (destination / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    (destination / 'SOURCE-README.txt').write_text(readme.decode('gb18030'))
    return {name: hashlib.sha256(data).hexdigest() for name, data in payload.items()}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('archive', type=Path)
    ap.add_argument('destination', type=Path)
    args = ap.parse_args()
    try:
        hashes = prepare(args.archive, args.destination)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile) as error:
        ap.exit(1, str(error) + '\n')
    print(json.dumps({'id': MOD_ID, 'source': SOURCE, 'files': hashes}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
