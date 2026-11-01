#!/usr/bin/env python3
"""Stage hash-checked public images after test installation; collect native results.

Run alongside blackboard_text_device_test.dart, with its redirected --test-log.
Images are not added to the APK. This does not decide visual accuracy acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources', required=True, type=Path)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--test-log', required=True, type=Path)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--package', default='dev.camereon.camereon.demo.detector_preview')
    args = parser.parse_args()
    sources = json.loads(args.sources.read_text())
    for source in sources:
        if not re.fullmatch(r'[a-z-]+', source['id']):
            parser.error('Invalid source ID')
        content = (args.input / (source['id'] + '.jpg')).read_bytes()
        if hashlib.sha256(content).hexdigest() != source['sha256']:
            parser.error('Image differs from source manifest: ' + source['id'])
    shell = ['adb', '-s', args.serial, 'shell', '-T']
    def wait_for(marker, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            log = args.test_log.read_text(errors='replace') if args.test_log.exists() else ''
            if marker in log:
                return
            if 'Test failed' in log or 'Failed to load' in log:
                raise RuntimeError('Device test failed; inspect its log')
            time.sleep(.5)
        raise TimeoutError('Waiting for device test marker: ' + marker)
    wait_for('public blackboards: native detection', 240)
    subprocess.run(shell + ['run-as', args.package, 'mkdir', '-p', 'files/blackboard-eval'], check=True)
    # A new manifest starts the test. Never expose half-written fixture files.
    def stage(name, data):
        target = 'files/blackboard-eval/' + name
        command = 'run-as ' + shlex.quote(args.package) + ' sh -c ' + shlex.quote('cat > ' + target + '.part')
        subprocess.run(shell + [command], input=data, check=True)
        subprocess.run(shell + ['run-as', args.package, 'mv', target + '.part', target], check=True)
    for source in sources:
        name = source['id'] + '.jpg'
        stage(name, (args.input / name).read_bytes())
    stage('sources.json', args.sources.read_bytes())
    print('Staged public fixtures', flush=True)
    wait_for('BLACKBOARD_READY', 240)
    args.output.mkdir(parents=True, exist_ok=True)
    for name in ['results.json', *[s['id'] + '-masked.jpg' for s in sources]]:
        with (args.output / name).open('wb') as output:
            subprocess.run(['adb', '-s', args.serial, 'exec-out', 'run-as', args.package,
                            'cat', 'files/blackboard-eval/' + name], stdout=output, check=True)
    subprocess.run(shell + ['run-as', args.package, 'touch', 'files/blackboard-eval/collected'], check=True)
    print('Collected public-image results and acknowledged test', flush=True)


if __name__ == '__main__':
    main()
