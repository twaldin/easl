#!/usr/bin/env python3
"""Link a prebuilt optimized CanvasApp; never build or launch it in compile-only mode."""
import argparse
import json
import math
import os
import pathlib
import platform
import shlex
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-path', required=True, type=pathlib.Path)
    parser.add_argument('--output', required=True, type=pathlib.Path)
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--width', type=int, default=4800)
    parser.add_argument('--height', type=int, default=3142)
    parser.add_argument('--frames', type=int, default=12)
    parser.add_argument('--format', choices=('png', 'jpeg'), default='png')
    parser.add_argument('--max-main-ms', type=float)
    parser.add_argument('--compare', type=pathlib.Path, help='Prior run output directory; compare decoded fixed-phase RGBA bytes')
    parser.add_argument('--max-channel-error', type=int, default=0)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Compilation and execution require macOS; --compile-only never runs AppKit.')
    if not (64 <= args.width <= 16384 and 64 <= args.height <= 16384 and args.frames >= 2):
        parser.error('Viewport axes must be 64..16384 and --frames at least 2.')
    if args.max_main_ms is not None and (not math.isfinite(args.max_main_ms) or args.max_main_ms <= 0):
        parser.error('--max-main-ms must be finite and positive.')
    if not 0 <= args.max_channel_error <= 255:
        parser.error('--max-channel-error must be 0..255.')
    root = pathlib.Path(__file__).resolve().parents[2]
    build = args.bin_path.resolve()
    link = build / 'Easl.product' / 'Objects.LinkFileList'
    if not link.is_file() or not (build / 'description.json').is_file():
        parser.error('Supply a native optimized testing-enabled Easl build; this runner never rebuilds it.')
    objects = [pathlib.Path(p) for p in shlex.split(link.read_text()) if pathlib.Path(p).name not in {'main.swift.o', 'main.o'}]
    for module in ('CanvasApp.build', 'CanvasCore.build'):
        if not any(module in p.parts for p in objects):
            parser.error(f'Link file has no {module} objects.')
    if any(not p.is_file() for p in objects):
        parser.error('Link file references missing compiled objects.')
    description = json.loads((build / 'description.json').read_text())
    app = next(v for v in description['swiftCommands'].values() if v['moduleName'] == 'CanvasApp')
    if '-O' not in app['otherArguments'] and '-Osize' not in app['otherArguments']:
        parser.error('CanvasApp must be optimized (-O or -Osize).')
    compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    command = [compiler, '-O', '-swift-version', '6', '-parse-as-library', '-enable-testing',
               '-sdk', sdk, '-target', f'{platform.machine()}-apple-macosx14.0',
               '-I', str(build / 'Modules'), '-I', str(build)]
    arguments = app['otherArguments']
    for index, argument in enumerate(arguments[:-1]):
        if argument == '-Xcc':
            command.extend(['-Xcc', arguments[index + 1]])
        elif argument == '-I' and 'libghostty' in arguments[index + 1]:
            command.extend(['-I', arguments[index + 1]])
    executable = build / 'BrowserCapture'
    command.append(str(root / 'Tests/BrowserCapture/BrowserCapture.swift'))
    command.extend(str(p) for p in objects)
    command.extend(['-F', str(build), '-L', str(build), '-lghostty', '-framework', 'AppKit',
                    '-framework', 'WebKit', '-framework', 'QuartzCore', '-framework', 'Carbon', '-lc++', '-o', str(executable)])
    subprocess.run(command, cwd=root, check=True)
    if args.compile_only:
        print(f'Compiled {executable}; no AppKit/WebKit execution, no runtime claim.')
        return
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error('--output must be empty to avoid mixing evidence.')
    with tempfile.TemporaryDirectory(prefix='easl-browser-capture-', dir='/tmp') as temporary:
        environment = os.environ.copy()
        environment.update(EASL_HOME=temporary, CFFIXED_USER_HOME=temporary, XDG_CONFIG_HOME=temporary, EASL_NO_ACTIVATE='1')
        environment.pop('EASL_ROOT', None)
        subprocess.run([str(executable), str(output), str(args.width), str(args.height), str(args.frames),
                        args.format, str(args.max_main_ms or 0)], cwd=root, env=environment,
                       check=True, timeout=90 + args.frames * 35)
    if args.compare:
        baseline = json.loads((args.compare / 'results.json').read_text())
        current = json.loads((output / 'results.json').read_text())
        if [(f['phase'], f['width'], f['height']) for f in baseline['frames']] != [(f['phase'], f['width'], f['height']) for f in current['frames']]:
            parser.error('Comparison requires identical phase count and decoded dimensions.')
        comparisons = []
        for frame in current['frames']:
            name = f"phase-{frame['phase']}.rgba"
            before, after = (args.compare / name).read_bytes(), (output / name).read_bytes()
            if len(before) != len(after) or not before:
                parser.error(f'Invalid comparison artifact: {name}')
            error = max(abs(a - b) for a, b in zip(before, after))
            comparisons.append({'phase': frame['phase'], 'maxChannelError': error})
        (output / 'comparison.json').write_text(json.dumps(comparisons, indent=2) + '\n')
        if any(c['maxChannelError'] > args.max_channel_error for c in comparisons):
            parser.error('Decoded pixels exceeded --max-channel-error; see comparison.json.')
    if args.max_main_ms is None:
        print('Measurements only: no main-thread timing pass claim (no --max-main-ms supplied).')


if __name__ == '__main__':
    main()
