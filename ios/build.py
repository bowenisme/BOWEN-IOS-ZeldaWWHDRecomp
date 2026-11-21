#!/usr/bin/env python3
"""Build the iPhone/iPad app; --stub makes an unsigned compile check without game code."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools/recomp'))
import builds

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--stub', action='store_true', help='unsigned compile check without game code')
ap.add_argument('--game', type=Path, help='your extracted Wii U game directory')
ap.add_argument('--check-game', action='store_true', help='validate game files without building')
ap.add_argument('--team', default=os.environ.get('DEVELOPMENT_TEAM'), help='Xcode development team ID')
ap.add_argument('--bundle-id', help='bundle identifier registered for your signing team')
ap.add_argument('--configuration', default='RelWithDebInfo', choices=['Debug','RelWithDebInfo','Release'])
a = ap.parse_args()
if a.stub and a.check_game:
    ap.error('--check-game requires real game files')
if a.stub and a.game is not None:
    ap.error('--stub cannot be combined with --game')
if a.check_game and a.game is None:
    ap.error('--check-game requires --game')
if not a.stub:
    if a.game is None:
        ap.error('an app build requires --game with your original extracted USA/EUR v0 game')
    game = a.game.expanduser().resolve()
    rpx = game / 'code/cking.rpx'
    if not rpx.is_file() or not (game / 'content').is_dir() or not (game / 'meta').is_dir():
        ap.error(f'expected code/cking.rpx, content/ and meta/ in {game}')
    build = builds.identify(str(rpx))
    if not build:
        ap.error(f'unsupported RPX SHA-256: {builds.file_sha256(str(rpx))}; use unmodified USA/EUR v0')
    print(f'Verified {build.name}, title {build.title_id}', flush=True)
    if a.check_game:
        raise SystemExit(0)
if not a.team:
    if not a.stub:
        ap.error('an app build requires DEVELOPMENT_TEAM or --team (your Xcode team ID)')
if not a.stub and not a.bundle_id:
    ap.error('an app build requires --bundle-id (an identifier registered for your team)')
cmake = shutil.which('cmake')
if not cmake:
    bundled = root / 'build/tools-python/cmake/data/bin/cmake'
    if bundled.is_file():
        cmake = str(bundled)
if not cmake:
    ap.error('cmake is required on the Mac')

def run(args):
    subprocess.run([str(x) for x in args], cwd=root, check=True)

variant = 'stub' if a.stub else 'game'
gen = root / ('build/gen-stub' if a.stub else 'build/gen-ios-game')
binary = root / f'build/ios-{variant}'
if a.stub:
    run([sys.executable, 'tools/recomp/stubgen.py', gen])
else:
    run([sys.executable, 'tools/recomp/recomp.py', rpx, gen])
cmake_args = [cmake, '-S', root, '-B', binary, '-G', 'Xcode', '-DCMAKE_SYSTEM_NAME=iOS',
     '-DCMAKE_OSX_SYSROOT=iphoneos', '-DCMAKE_OSX_ARCHITECTURES=arm64',
     '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0', '-DWWHD_RENDERER=METAL', f'-DGEN_DIR={gen}',
     ]
if a.stub:
    cmake_args.append('-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO')
else:
    cmake_args.append(f'-DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM={a.team}')
    cmake_args.append(f'-DWWHD_IOS_BUNDLE_ID={a.bundle_id}')
run(cmake_args)
xcodebuild_args = ['xcodebuild', '-project', binary/'wwhd_recomp.xcodeproj', '-scheme', 'wwhd',
     '-configuration', a.configuration, '-destination', 'generic/platform=iOS',
     *([] if a.stub else ['-allowProvisioningUpdates']),
     # show every compile error in one run instead of stopping at the first file
     '-IDEBuildingContinueBuildingAfterErrors=YES', '-jobs', '4', 'build']
if a.stub:
    xcodebuild_args.append('CODE_SIGNING_ALLOWED=NO')
run(xcodebuild_args)
print(f'App: {binary}/{a.configuration}-iphoneos/wwhd.app')
if a.stub:
    print('This unsigned stub has no game code and cannot be installed or played.')
else:
    print('Copy the verified game folder to the installed app Documents/game before launching.')
