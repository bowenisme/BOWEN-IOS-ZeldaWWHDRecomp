#!/usr/bin/env python3
"""Check current source candidates or an explicit export directory; uploads nothing."""
import argparse
from collections import Counter
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAX_FILES = 10000
MAX_TEXT_FILE = 4 * 1024 * 1024
MAX_CONTENT_TOTAL = 128 * 1024 * 1024
MAX_REVIEWED_BINARY = 16 * 1024 * 1024
PRIVATE_SUFFIXES = {
    '.rpx', '.wud', '.wux', '.wua', '.iso', '.rvz', '.gcm', '.wbfs',
    '.key', '.p12', '.p8', '.pem', '.der', '.cer', '.crt', '.pfx',
    '.mobileprovision', '.ipa', '.sav', '.savestate', '.state', '.srm',
    '.gci', '.gcs', '.ips', '.crash', '.dmp', '.spindump', '.xcuserstate',
    '.bak', '.backup', '.orig', '.trace', '.zip', '.pack', '.szs', '.sarc',
}
PRIVATE_DIRS = {
    '.git', 'savestate', 'savestates', 'save_states', 'xcuserdata',
    'deriveddata', 'wwhd_src', 'audit-private', 'device-reports', 'diagnostics',
    'cmakefiles', '.build', 'localization-source',
}
ROOT_PRIVATE_DIRS = {
    'game', 'save', 'saves', 'rom', 'roms', 'build', 'out', 'captures',
    'capture', 'screenshots', 'screenshot', 'backups', 'decomp', 'tww',
}
BINARY_SUFFIXES = {
    '.png', '.jpg', '.jpeg', '.heic', '.ttf', '.otf', '.woff', '.woff2', '.bin', '.dat',
    '.pdf', '.a', '.o', '.dylib', '.so', '.dll', '.exe', '.metallib', '.air', '.car',
    '.icns', '.gif', '.webp', '.bmp',
}
REVIEWED_PUBLIC_BINARY_SHA256 = {
    # Exact files confirmed by source/license review; no extension-wide binary exemptions.
    'runtime/assets/fonts/WWHDSettingsSansSC-Regular.ttf': 'bdef17d50f23cb51899e4a33a0da19c2c2b3e3a9c3cac85e9c01586962cd8645',
    'android/icon/app_icon_1024.png': 'a694242c9207b074fb2ec21ab1755ca0471374f06dba6c257ad5d38fd2fd319f',
    'android/app/src/main/res/drawable-nodpi/ic_launcher_art.png': '60d7c42baf6bf8501e25be628378250f22e5935362e3aba1ca9cd447e89e66da',
    'android/app/src/main/res/mipmap-hdpi/ic_launcher.png': '90438b11e75782815efac51cc2e421913392f7d0f800a076f6f9ccd20957662f',
    'android/app/src/main/res/mipmap-mdpi/ic_launcher.png': '1b3e251056fe61b97f491e0669d58fdf5cdefe1438a638e1603d467c47e5ee29',
    'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': '69379469068a8b77ecc40c36d1b384e473a1d05f5c5a88bf0e11738330d2aeff',
    'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': 'bc1f07dd93144362212fe797c313628399e71f9877f7ec779c7218348bd9f5c8',
    'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': '0430159468fdb0eb8dfbd65f50b7f193f6bc4d57d7ad5a91928ec092810f73fd',
    'android/gradle/wrapper/gradle-wrapper.jar': '2db75c40782f5e8ba1fc278a5574bab070adccb2d21ca5a6e5ed840888448046',
    'examples/guest-mods/button-icons/assets/a.png': '304e6d80df64dd5504d97cff3156082763880e5db2bec4c5888681bd6c0b99a7',
    'examples/guest-mods/button-icons/assets/b.png': 'c2a09c9b9855095d9339844e4419ab70435067dad091446a8c7f437b333a9f59',
    'examples/guest-mods/button-icons/assets/r.png': '0e39398941defc4bafb22c336defbca355dab7db32a373d1f67ecf00131f7ce3',
    'examples/guest-mods/button-icons/assets/x.png': '9495697d46687c4ef2c941493209aa3f1a5126914246624a234e15763073b340',
    'examples/guest-mods/button-icons/assets/y.png': '103ddb40aefa8d0821b92ce34937367ee2498e18e1955bdc18b6a7f369bccabd',
    'examples/guest-mods/hud-demo/assets/tile.png': 'f1f7b84436e9d067e9f6bfb3e3346468fded8771dcd424874bfb92771d227b9d',
}
KEY = re.compile(rb'^\s*-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', re.MULTILINE)
SECRET_PATTERNS = (
    ('cloud credential marker', re.compile(rb'AKIA[A-Z0-9]{16}')),
    ('source hosting token marker', re.compile(rb'github_pat_[A-Za-z0-9_]{20,255}|gh[pousr]_[A-Za-z0-9_]{20,255}')),
    ('absolute user path', re.compile(rb'/' + rb'(?:Users|home)/[^/\r\n]+' + rb'/')),
    ('absolute user path', re.compile(rb'\b[A-Za-z]:\\Users\\[^\\/\r\n]+\\', re.IGNORECASE)),
    ('personal signing setting', re.compile(rb'\bDEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\b')),
    ('personal signing setting', re.compile(rb'\bCODE_SIGN_IDENTITY\s*=\s*"?Apple (?:Development|Distribution):[^\r\n;]+', re.IGNORECASE)),
    ('personal signing setting', re.compile(rb'\bPROVISIONING_PROFILE_SPECIFIER\s*=\s*[^\s;"\r\n]+', re.IGNORECASE)),
    ('personal account setting', re.compile(rb'\b(?:APPLE_ID|FASTLANE_USER|APP_STORE_CONNECT_USERNAME)\s*[:=]\s*[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', re.IGNORECASE)),
    ('device identifier', re.compile(rb'\b(?:UDID|device[_ -]?identifier)\s*[:=]\s*["\']?[0-9A-F-]{20,40}', re.IGNORECASE)),
)
SCREENSHOT_NAME = re.compile(r'^(?:screenshot.*|screen shot[ _-].*)\.(?:png|jpe?g|heic)$', re.IGNORECASE)
SLOT_NAME = re.compile(r'slot\d+\.(?:bin(?:\.preview)?|sav|state|png|full\..*\.png)$', re.IGNORECASE)


def private_path(name):
    normalized = name.replace('\\', '/')
    path = PurePosixPath(normalized)
    parts = tuple(part.casefold() for part in path.parts)
    if (parts and parts[0] in ROOT_PRIVATE_DIRS) or any(part in PRIVATE_DIRS for part in parts):
        return 'private or generated directory'
    if any(part in {'build', 'out'} and not any(parent in {'src', 'include', 'third_party', 'tools', 'docs', 'examples'} for parent in parts[:index])
           for index, part in enumerate(parts)):
        return 'private or generated directory'
    if parts[:2] == ('ios', 'icons'):
        return 'personal or derived image asset'
    if any(part.endswith(('.app', '.xcarchive', '.xcresult', '.dsym')) for part in parts):
        return 'built application or signing output'
    if path.suffix.casefold() in PRIVATE_SUFFIXES:
        return 'game, save, diagnostic, backup, or signing file'
    if path.name.casefold() in {'.env', '.netrc'} or (path.name.casefold().startswith('.env.') and
            path.name.casefold() not in {'.env.example', '.env.sample', '.env.template'}):
        return 'local credential configuration'
    if SCREENSHOT_NAME.fullmatch(path.name) or SLOT_NAME.fullmatch(path.name):
        return 'personal capture or save slot'
    if normalized.startswith('ios/') and '验证' in path.name:
        return 'local device report'
    return None


def private_content(data):
    if KEY.search(data):
        return 'private key marker'
    for reason, pattern in SECRET_PATTERNS:
        if pattern.search(data):
            return reason
    return None


def canonical_explicit_path(raw):
    path = Path(os.path.abspath(Path(raw).expanduser()))
    if sys.platform == 'darwin':
        for alias, target in ((Path('/tmp'), Path('/private/tmp')), (Path('/var'), Path('/private/var'))):
            try:
                path = target / path.relative_to(alias)
                break
            except ValueError:
                pass
    return path


def safe_path_label(path):
    value = Path(path).as_posix()
    match = re.match(r'^(?:[A-Za-z]:)?/(?:Users|home)/[^/]+/(.*)$', value, re.IGNORECASE)
    if match:
        return match.group(1) or Path(path).name
    if value.startswith('/private/tmp/'):
        return value[len('/private/tmp/'):]
    if value.startswith('/private/var/folders/'):
        parts = value.split('/')
        try:
            return '/'.join(parts[parts.index('T') + 1:]) or Path(path).name
        except ValueError:
            return Path(path).name
    return value.lstrip('/')


def symlink_ancestor(path):
    current = Path(path)
    while True:
        try:
            if current.is_symlink():
                return current
        except OSError:
            return current
        parent = current.parent
        if parent == current:
            return None
        current = parent


def explicit_path_issue(path):
    parts = tuple(part.casefold() for part in Path(path).parts)
    for index, part in enumerate(parts):
        prefix = parts[:index]
        source_context = any(parent in {'src', 'include', 'third_party', 'tools', 'docs', 'examples'} for parent in prefix)
        if part in PRIVATE_DIRS:
            return 'private or generated directory'
        if part in {'decomp', 'tww'}:
            if 'tools' in prefix or any(prefix[i:i + 2] == ('runtime', 'src') for i in range(max(0, len(prefix) - 1))):
                continue
            return 'private or generated directory'
        if part in ROOT_PRIVATE_DIRS and not source_context:
            return 'private or generated directory'
        if part.endswith(('.app', '.xcarchive', '.xcresult', '.dsym')):
            return 'built application or signing output'
        if PurePosixPath(part).suffix in PRIVATE_SUFFIXES:
            return 'game, save, diagnostic, backup, or signing file'
    return None


def reviewed_binary_key(name):
    normalized = name.replace('\\', '/').lstrip('/')
    for candidate in REVIEWED_PUBLIC_BINARY_SHA256:
        if normalized == candidate or normalized.endswith('/' + candidate):
            return candidate
    return None


def looks_binary(data, name):
    if PurePosixPath(name).suffix.casefold() in BINARY_SUFFIXES or b'\0' in data:
        return True
    try:
        data.decode('utf-8')
    except UnicodeDecodeError:
        return True
    return any(byte < 9 or 13 < byte < 32 for byte in data)


def git_candidates():
    result = subprocess.run(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
        cwd=ROOT, check=True, stdout=subprocess.PIPE,
    )
    return [(ROOT / name, name) for name in result.stdout.decode('utf-8').split('\0') if name]


def explicit_candidates(roots):
    files, issues = [], []
    for raw in roots:
        root = canonical_explicit_path(raw)
        label = safe_path_label(root)
        linked = symlink_ancestor(root)
        if linked:
            issues.append((safe_path_label(linked), 'symlink in explicit path ancestry'))
            continue
        path_issue = explicit_path_issue(root)
        if path_issue:
            issues.append((label, path_issue))
            continue
        if not root.exists():
            issues.append((label, 'candidate path is missing'))
            continue
        if root.is_file():
            files.append((root, label))
            continue
        if not root.is_dir():
            issues.append((label, 'candidate path is not a regular file or directory'))
            continue
        stack = [(root, '', 0)]
        while stack:
            directory, relative, depth = stack.pop()
            try:
                entries = sorted(directory.iterdir(), key=lambda p: p.name.casefold(), reverse=True)
            except OSError:
                issues.append((relative or label, 'directory cannot be inspected'))
                continue
            for entry in entries:
                name = f'{relative}/{entry.name}' if relative else entry.name
                if entry.is_symlink():
                    issues.append((name, 'symlink requires manual review'))
                    continue
                path_issue = private_path(name)
                if path_issue:
                    issues.append((name, path_issue))
                    continue
                if entry.is_dir():
                    if depth >= 32:
                        issues.append((name, 'directory depth limit reached'))
                    else:
                        stack.append((entry, name, depth + 1))
                elif entry.is_file():
                    files.append((entry, name))
                    if len(files) >= MAX_FILES:
                        issues.append((name, 'file count limit reached'))
                        return files, issues
                else:
                    issues.append((name, 'non-regular file requires manual review'))
    return files, issues


def inspect_candidates(candidates, initial_issues=()):
    issues = list(initial_issues)
    content_bytes = 0
    for path, name in candidates[:MAX_FILES]:
        if path.is_symlink():
            issues.append((name, 'symlink requires manual review'))
            continue
        if path.is_dir():
            issues.append((name, 'directory candidate requires export review'))
            continue
        path_issue = private_path(name)
        if path_issue:
            issues.append((name, path_issue))
            continue
        try:
            size = path.stat().st_size
            approved = reviewed_binary_key(name)
            if approved:
                if size > MAX_REVIEWED_BINARY:
                    issues.append((name, 'reviewed binary size limit reached'))
                    continue
                if content_bytes + size > MAX_CONTENT_TOTAL:
                    issues.append((name, 'content scan byte limit reached'))
                    continue
                with path.open('rb') as stream:
                    data = stream.read(MAX_REVIEWED_BINARY + 1)
                content_bytes += len(data)
                if len(data) != size or hashlib.sha256(data).hexdigest() != REVIEWED_PUBLIC_BINARY_SHA256[approved]:
                    issues.append((name, 'reviewed public binary hash mismatch'))
                continue
            if size > MAX_TEXT_FILE:
                if content_bytes + min(size, 4096) > MAX_CONTENT_TOTAL:
                    issues.append((name, 'content scan byte limit reached'))
                    continue
                with path.open('rb') as stream:
                    sample = stream.read(4096)
                content_bytes += len(sample)
                if looks_binary(sample, name):
                    issues.append((name, 'unknown binary or resource requires manual review'))
                else:
                    issues.append((name, 'oversized text requires manual review'))
                continue
            if content_bytes + size > MAX_CONTENT_TOTAL:
                issues.append((name, 'content scan byte limit reached'))
                continue
            with path.open('rb') as stream:
                data = stream.read(MAX_TEXT_FILE + 1)
            content_bytes += len(data)
            if len(data) > MAX_TEXT_FILE:
                issues.append((name, 'file grew beyond content scan limit'))
                continue
        except OSError:
            issues.append((name, 'file cannot be inspected'))
            continue
        if looks_binary(data, name):
            issues.append((name, 'unknown binary or resource requires manual review'))
            continue
        content_issue = private_content(data)
        if content_issue:
            issues.append((name, content_issue))
    if len(candidates) > MAX_FILES:
        issues.append(('', 'file count limit reached'))
    return sorted(set(issues), key=lambda item: (item[1], item[0]))


def self_test():
    positives = [
        'game/code/main.rpx', 'dump.WUA', 'save/slot5.bin', 'slot2.bin.preview',
        'ios/profile.mobileprovision', 'DerivedData/App.app/Payload',
        'runtime/logs/session.ips', 'Screenshots/Screen Shot 1.png',
        'wwhd_src/generated.cpp', 'backup/original.cpp.orig',
        'localization-source/Cafe/Source.cpp', 'signing/distribution.pem',
        'decomp/generated.c', 'tww/source.c',
        'Screenshot001.png', 'release/content/Common/Pack/permanent_2d_UsEnglish.pack',
        'release/content/Common/Layout/Title_00.szs', 'release/archive.zip',
    ]
    negatives = [
        'runtime/src/input.h', 'runtime/src/platform/keycodes.h', 'ios/README.md',
        'tools/savegame/README.md', 'third_party/example/LICENSE', 'android/icon/app_icon_1024.png',
        'docs/screenshot-guide.md', '.env.example',
        'runtime/guest/include/wwhd/bindings.h', 'runtime/guest/include/wwhd/functions.h',
        'runtime/guest/include/wwhd/public-wwhd-LICENSE',
        'runtime/src/decomp/example.cpp', 'tools/decomp/setup.py',
    ]
    assert all(private_path(name) for name in positives)
    assert all(not private_path(name) for name in negatives)
    assert KEY.search(b'-----BEGIN PRIVATE KEY-----\nplaceholder')
    assert not KEY.search(b'const char* marker="-----BEGIN PRIVATE KEY-----";')
    assert private_content(Path(__file__).read_bytes()) is None
    assert private_content((b'/' + b'Users/sample/Library/Signing.plist')) == 'absolute user path'
    assert private_content(b'/' + b'Users/' + '示例 用户'.encode() + b'/Library/file') == 'absolute user path'
    assert private_content(b'C:\\Users\\' + '示例 用户'.encode() + b'\\Documents\\file') == 'absolute user path'
    assert private_content(b'DEVELOPMENT_' + b'TEAM = A1B2C3D4E5;') == 'personal signing setting'
    assert private_content(b'APPLE_ID' + b' = ' + b'dev@example.invalid') == 'personal account setting'
    assert private_content(b'UD' + b'ID = ' + b'00000000-0000-0000-0000-000000000000') == 'device identifier'

    with tempfile.TemporaryDirectory(prefix='source-release-check-') as temporary:
        root = Path(temporary) / 'export'
        (root / 'runtime/src').mkdir(parents=True)
        (root / 'third_party/example').mkdir(parents=True)
        (root / 'ios').mkdir()
        (root / 'game').mkdir()
        (root / 'runtime/src/input.h').write_text('int safe_source;\n')
        (root / 'third_party/example/LICENSE').write_text('MIT License\n')
        (root / 'ios/Build.xcconfig').write_bytes(b'DEVELOPMENT_' + b'TEAM = A1B2C3D4E5;')
        (root / 'game/ROM.WUD').write_bytes(b'fake game input')
        (root / 'assets').mkdir()
        (root / 'assets/unknown.bin').write_bytes(b'\x89PNG\r\n\x00fixture')
        (root / 'assets/large.dat').write_bytes(b'\x00' + b'x' * MAX_TEXT_FILE)
        outside = Path(temporary) / 'external.txt'
        outside.write_text('not followed')
        (root / 'linked.txt').symlink_to(outside)
        candidates, discovery_issues = explicit_candidates([root])
        findings = inspect_candidates(candidates, discovery_issues)
        reasons = {reason for _, reason in findings}
        assert 'private or generated directory' in reasons
        assert 'personal signing setting' in reasons
        assert 'symlink requires manual review' in reasons
        assert not any(name.endswith('LICENSE') for name, _ in findings)
        assert explicit_candidates([root / 'runtime/src/input.h'])[0]
        unknown = inspect_candidates([(root / 'assets/unknown.bin', 'assets/unknown.bin')])
        assert ('assets/unknown.bin', 'unknown binary or resource requires manual review') in unknown
        large = inspect_candidates([(root / 'assets/large.dat', 'assets/large.dat')])
        assert ('assets/large.dat', 'unknown binary or resource requires manual review') in large

        direct_game = root / 'game/content/level.dat'
        direct_game.parent.mkdir(parents=True)
        direct_game.write_text('local data')
        game_candidates, game_issues = explicit_candidates([direct_game])
        assert not game_candidates and game_issues[0][1] == 'private or generated directory'
        assert 'game/content/level.dat' in game_issues[0][0]

        app_file = root / 'ios/Preview.app/Contents/Info.plist'
        app_file.parent.mkdir(parents=True)
        app_file.write_text('local build')
        app_candidates, app_issues = explicit_candidates([app_file])
        assert not app_candidates and app_issues[0][1] == 'built application or signing output'

        (root / 'decomp').mkdir()
        assert explicit_candidates([root / 'decomp'])[1][0][1] == 'private or generated directory'
        assert explicit_path_issue(root / 'runtime/src/decomp/file.cpp') is None
        assert explicit_path_issue(root / 'tools/decomp/setup.py') is None

        real = Path(temporary) / 'real'
        (real / 'export').mkdir(parents=True)
        alias = Path(temporary) / 'alias'
        alias.symlink_to(real, target_is_directory=True)
        aliased_files, aliased_issues = explicit_candidates([alias / 'export'])
        assert not aliased_files and aliased_issues[0][1] == 'symlink in explicit path ancestry'
        assert not aliased_issues[0][0].startswith('/')

        approved_key = 'runtime/assets/fonts/WWHDSettingsSansSC-Regular.ttf'
        approved = root / approved_key
        approved.parent.mkdir(parents=True)
        approved.write_bytes(b'\x00public fixture')
        old_hash = REVIEWED_PUBLIC_BINARY_SHA256[approved_key]
        REVIEWED_PUBLIC_BINARY_SHA256[approved_key] = hashlib.sha256(approved.read_bytes()).hexdigest()
        assert not inspect_candidates([(approved, approved_key)])
        REVIEWED_PUBLIC_BINARY_SHA256[approved_key] = old_hash
        assert ('runtime/assets/fonts/WWHDSettingsSansSC-Regular.ttf', 'reviewed public binary hash mismatch') in inspect_candidates([(approved, approved_key)])
    print('PASS: source paths, secrets, explicit exports, symlinks, and safe license/source fixtures')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--path', nargs='+', help='inspect these explicit files or export directories (including ignored files)')
    parser.add_argument('--private-report', help='write relative candidate paths and blocker classes to a private local report')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.path:
        candidates, discovery_issues = explicit_candidates(args.path)
    else:
        candidates, discovery_issues = git_candidates(), []
    issues = inspect_candidates(candidates, discovery_issues)
    if args.private_report:
        report = Path(args.private_report).expanduser()
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text('\n'.join(f'{reason}\t{name}' for name, reason in issues) + ('\n' if issues else 'PASS\n'))
    print(f'{len(candidates)} candidate files inspected; {len(issues)} blockers. No files uploaded.')
    for reason, count in sorted(Counter(reason for _, reason in issues).items()):
        print(f'BLOCK: {reason} ({count})')
    print('This checks current file candidates and bounded content, not Git history or redistribution permissions.')
    if args.private_report:
        print('Detailed relative paths were written to the requested private report.')
    return 1 if issues else 0


if __name__ == '__main__':
    raise SystemExit(main())
