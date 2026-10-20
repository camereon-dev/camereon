#!/usr/bin/env python3
"""Build and run a standalone Android image-input evaluation. No risk scoring."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request

TOOL = Path(__file__).resolve().parent
ROOT = TOOL.parent.parent
PACKAGE = 'dev.camereon.camereon_vlm_eval'
WORK = Path(os.environ.get('VLM_EVAL_DIR', '/private/tmp/camereon-vlm-eval')).expanduser().resolve()
APP = WORK / 'app'
MODEL_FILES = {'gemma4': 'model.json', 'smolvlm2': 'smolvlm2.json'}


def run(arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def fetch_model(candidate):
    model = json.loads((TOOL / MODEL_FILES[candidate]).read_text())
    target = WORK/'models'/model['filename']
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if target.stat().st_size != model['size'] or digest(target) != model['sha256']:
            raise ValueError(f'Cached model checksum mismatch: {target}')
        return target
    url = f'https://huggingface.co/{model["repository"]}/resolve/{model["revision"]}/{model["filename"]}'
    partial = target.with_suffix('.part')
    print(f'Downloading {model["name"]}: {model["size"] / 1e9:.2f} GB', flush=True)
    checksum = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=120) as source, partial.open('wb') as output:
        previous = time.monotonic()
        total = 0
        while chunk := source.read(8*1024*1024):
            output.write(chunk)
            checksum.update(chunk)
            total += len(chunk)
            if time.monotonic()-previous > 15:
                print(f'{total / 1e6:.0f}/{model["size"] / 1e6:.0f} MB', flush=True)
                previous = time.monotonic()
    if partial.stat().st_size != model['size'] or checksum.hexdigest() != model['sha256']:
        partial.unlink()
        raise ValueError('Downloaded model checksum mismatch')
    partial.rename(target)
    return target


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    if not (APP / 'pubspec.yaml').exists():
        run(['flutter', 'create', '--no-pub', '--platforms=android', '--org', 'dev.camereon',
             '--project-name', 'camereon_vlm_eval', '--empty', APP], cwd=ROOT)
    if not re.search(r'^name:\s*camereon_vlm_eval\s*$', (APP / 'pubspec.yaml').read_text(), re.MULTILINE):
        raise ValueError('The work directory does not belong to this evaluation app')
    shutil.copyfile(TOOL/'pubspec.yaml.template', APP/'pubspec.yaml')
    for name in ('main.dart', 'evaluator.dart'):
        shutil.copyfile(TOOL/(name+'.template'), APP/'lib'/name)
    locked = (TOOL/'pubspec.lock').exists()
    if locked:
        shutil.copyfile(TOOL/'pubspec.lock', APP/'pubspec.lock')
    run([sys.executable, TOOL/'make_images.py', APP/'assets/eval'])
    gradle = APP/'android/app/build.gradle.kts'
    config = gradle.read_text()
    config, count = re.subn(r'minSdk\s*=\s*(?:flutter.minSdkVersion|30)', 'minSdk = 30', config)
    if count != 1:
        raise ValueError('Cannot set the standalone app minSdk')
    # Flutter's target-platform excludes other Flutter engines, but AARs can
    # still contribute JNI libraries for other ABIs. The LiteRT runtime is ARM64.
    if 'abiFilters.add("arm64-v8a")' not in config:
        config = config.replace('minSdk = 30', 'minSdk = 30\n        ndk {\n            abiFilters.clear()\n            abiFilters.add("arm64-v8a")\n        }', 1)
    gradle.write_text(config)
    manifest = APP/'android/app/src/main/AndroidManifest.xml'
    xml = manifest.read_text().replace('android:label="camereon_vlm_eval"', 'android:label="camereon Gemma eval"')
    # Explicitly remove transitive network permission: inference is local and
    # the host copies the model. This is not a production model downloader.
    if 'xmlns:tools=' not in xml:
        xml = xml.replace('<manifest ', '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
    if 'tools:node="remove"' not in xml:
        xml = xml.replace('    <application', '    <uses-permission android:name="android.permission.INTERNET" tools:node="remove"/>\n    <application', 1)
    manifest.write_text(xml)
    for variant in ('debug', 'profile'):
        variant_manifest = APP/f'android/app/src/{variant}/AndroidManifest.xml'
        if variant_manifest.exists():
            text = variant_manifest.read_text()
            text = re.sub(r'<uses-permission\s+android:name="android.permission.INTERNET"\s*/>', '', text)
            variant_manifest.write_text(text)
    command = ['flutter', 'pub', 'get'] + (['--enforce-lockfile'] if locked else [])
    run(command, cwd=APP)
    print(f'Evaluation source prepared: {APP}', flush=True)


def build():
    run(['flutter', 'build', 'apk', '--debug', '--target-platform', 'android-arm64'], cwd=APP)
    apk = APP/'build/app/outputs/flutter-apk/app-debug.apk'
    sdk = Path(os.environ.get('ANDROID_HOME', str(Path.home()/'Library/Android/sdk')))
    versions = [path for path in (sdk/'build-tools').iterdir()
                if re.fullmatch(r'\d+\.\d+\.\d+', path.name) and (path/'aapt').is_file()]
    aapt = max(versions, key=lambda path: tuple(map(int, path.name.split('.'))))/'aapt'
    permissions = subprocess.check_output([str(aapt), 'dump', 'permissions', str(apk)], text=True)
    if 'android.permission.INTERNET' in permissions:
        raise ValueError('Evaluation APK unexpectedly has network permission')
    badging = subprocess.check_output([str(aapt), 'dump', 'badging', str(apk)], text=True)
    abis = re.search(r'^native-code: (.+)$', badging, re.MULTILINE)
    if not abis or abis.group(1).strip() != "'arm64-v8a'":
        raise ValueError('Evaluation APK must contain ARM64 native libraries only')
    build_info = {
        'mode': 'debug', 'apk_sha256': digest(apk),
        'harness': {name:digest(TOOL/name) for name in
                    ('main.dart.template', 'evaluator.dart.template', 'pubspec.yaml.template',
                     'make_images.py', 'model.json', 'smolvlm2.json', 'run.py', 'pubspec.lock') if (TOOL/name).exists()},
        'resolved_lock_sha256':digest(APP/'pubspec.lock'),
        'permissions':permissions,
        'fixtures': {str(p.relative_to(TOOL)):digest(p) for p in
                     sorted((TOOL/'fixtures').iterdir()) if p.is_file()},
    }
    (WORK/'build-info.json').write_text(json.dumps(build_info, indent=2)+'\n')
    print(f'Evaluation APK: {apk}', flush=True)
    return apk


def device(serial):
    adb = ['adb'] + (['-s', serial] if serial else [])
    if not serial:
        lines = subprocess.check_output(['adb', 'devices'], text=True).splitlines()[1:]
        ready = [line.split()[0] for line in lines if len(line.split()) >= 2 and line.split()[1] == 'device']
        if len(ready) != 1:
            raise ValueError('Connect one Android device, or set ANDROID_SERIAL / --serial')
        adb = ['adb', '-s', ready[0]]
    run(adb + ['get-state'], stdout=subprocess.DEVNULL)
    def prop(name):
        return subprocess.check_output(adb+['shell', 'getprop', name], text=True).strip()
    info = {
        'model': prop('ro.product.model'), 'android': prop('ro.build.version.release'),
        'api': int(prop('ro.build.version.sdk')), 'abis': prop('ro.product.cpu.abilist'),
        'hardware': prop('ro.hardware'), 'emulator': prop('ro.kernel.qemu') == '1',
        'memory': subprocess.check_output(adb+['shell', 'cat', '/proc/meminfo'], text=True).splitlines()[0],
    }
    if info['api'] < 30 or 'arm64-v8a' not in info['abis']:
        raise ValueError('This evaluation requires Android API 30+ and ARM64')
    return adb, info


def shell(adb, arguments, **kwargs):
    return subprocess.run(adb+['shell', '-T', shlex.join([str(value) for value in arguments])], **kwargs)


def app_shell(adb, arguments, **kwargs):
    return shell(adb, ['run-as', PACKAGE]+arguments, **kwargs)


def copy_private(adb, host, remote):
    # No /sdcard permissions, public model copy, or command-line credentials.
    with host.open('rb') as source:
        result = app_shell(adb, ['sh', '-c', f'cat > {shlex.quote(remote)}.part'], stdin=source)
    if result.returncode:
        raise RuntimeError('Could not stream file into the evaluation app')
    app_shell(adb, ['mv', remote+'.part', remote], check=True)


def execute_connected(arguments, apk, adb, info):
    MODEL = json.loads((TOOL / MODEL_FILES[arguments.candidate]).read_text())
    path = Path(arguments.model or '').expanduser()
    if not path.is_file():
        raise ValueError('Set GEMMA_MODEL or --model to the selected .litertlm file. See README.')
    print(f'Verifying {MODEL["name"]} checksum...', flush=True)
    if path.stat().st_size != MODEL['size'] or digest(path) != MODEL['sha256']:
        raise ValueError('Model size/SHA-256 does not match model.json; no inference was run')
    print(f'Device: {info["model"]}, API {info["api"]}, {info["memory"]}', flush=True)
    run(adb+['install', '-r', apk])
    run(adb+['shell', 'am', 'force-stop', PACKAGE])
    app_shell(adb, ['mkdir', '-p', 'files/models'], check=True)
    internal = 'files/models/'+MODEL['filename']
    existing = app_shell(adb, ['sha256sum', internal], text=True, capture_output=True)
    if existing.returncode or not existing.stdout.startswith(MODEL['sha256']+' '):
        storage = subprocess.check_output(adb+['shell', 'df', '-k', '/data'], text=True).splitlines()[-1].split()
        # Initial CPU runs generated ~963 MiB / ~291 MiB of XNNPACK cache.
        # Also leave room for the OS, APK updates and temporary files.
        working_space = (2 if arguments.candidate == 'gemma4' else 1)*1024**3
        if int(storage[3])*1024 < MODEL['size'] + working_space:
            raise ValueError('Not enough device storage for the model plus working space')
        print(f'Copying {MODEL["size"] / 1e9:.2f} GB model to app-private storage...', flush=True)
        copy_private(adb, path, internal)
        copied = app_shell(adb, ['sha256sum', internal], text=True, capture_output=True, check=True)
        if not copied.stdout.startswith(MODEL['sha256']+' '):
            app_shell(adb, ['rm', '-f', internal], check=True)
            raise ValueError('Device model checksum mismatch')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    results = WORK/'results'/stamp
    results.mkdir(parents=True)
    model_path = '/data/user/0/'+PACKAGE+'/'+internal
    config = {'model':MODEL, 'model_path':model_path, 'backend':arguments.backend,
              'repeats':arguments.repeats, 'language':arguments.language,
              'max_output_tokens':arguments.max_output_tokens, 'with_ocr':arguments.with_ocr,
              'only_images':arguments.only_image}
    extra_images = []
    if arguments.images:
        from PIL import Image, ImageOps
        directory = Path(arguments.images).expanduser()
        if not directory.is_dir():
            raise ValueError('--images must point to a directory')
        inputs = sorted(p for p in directory.iterdir() if p.suffix.lower() in {'.jpg','.jpeg','.png','.webp'})
        if not 1 <= len(inputs) <= 10:
            raise ValueError('--images must contain 1-10 JPEG/PNG/WebP images')
        private_inputs = results/'private-images'
        private_inputs.mkdir()
        app_shell(adb, ['rm', '-rf', 'files/eval-images'], check=True)
        app_shell(adb, ['mkdir', '-p', 'files/eval-images'], check=True)
        for index, source in enumerate(inputs, start=1):
            name = f'user_{index:02d}.jpg'
            output = private_inputs/name
            with Image.open(source) as raw:
                image = ImageOps.exif_transpose(raw).convert('RGB')
                image.thumbnail((1024, 1024))
                image.save(output, 'JPEG', quality=92)
                dimensions = {'width':image.width, 'height':image.height}
            copy_private(adb, output, 'files/eval-images/'+name)
            extra_images.append({'id':f'user_{index:02d}', 'file':name, 'sha256':digest(output), **dimensions})
        config['images'] = extra_images
    config_path = results/'eval-config.json'
    config_path.write_text(json.dumps(config, indent=2)+'\n')
    copy_private(adb, config_path, 'files/eval-config.json')
    app_shell(adb, ['rm', '-f', 'files/eval-result.json', 'files/eval-result.json.part'], check=True)
    metadata = {
        'device':info, 'build_mode':'debug', 'model':MODEL,
        'build':json.loads((WORK/'build-info.json').read_text()),
        'fixtures':json.loads((APP/'assets/eval/manifest.json').read_text()),
        'private_images':extra_images,
        'started_at':datetime.now(timezone.utc).isoformat(),
        'note':'RSS/PSS do not represent all GPU allocations. Semantic review is required.',
    }
    (results/'environment.json').write_text(json.dumps(metadata, indent=2)+'\n')
    run(adb+['shell', 'am', 'start', '-W', '-n', PACKAGE+'/.MainActivity'])
    deadline = time.monotonic()+arguments.timeout
    started = time.monotonic()
    phase = None
    report = None
    try:
        while time.monotonic() < deadline:
            raw = app_shell(adb, ['cat', 'files/eval-result.json'], text=True, capture_output=True)
            if raw.returncode == 0:
                try:
                    report = json.loads(raw.stdout)
                except json.JSONDecodeError:
                    report = None
                if report:
                    (results/'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
                    if report.get('phase') != phase:
                        phase = report.get('phase')
                        print(f'[{report.get("status")}] {phase}', flush=True)
                    if report.get('status') in {'completed','failed','preflight_failed'}:
                        break
            memory = subprocess.run(adb+['shell','dumpsys','meminfo',PACKAGE], text=True, capture_output=True)
            with (results/'memory.txt').open('a') as stream:
                stream.write(datetime.now(timezone.utc).isoformat()+'\n'+memory.stdout+'\n')
            alive = subprocess.run(adb+['shell','pidof',PACKAGE], text=True, capture_output=True)
            if time.monotonic()-started > 15 and alive.returncode:
                raise RuntimeError('Evaluation process stopped before completion (check crash/OS memory logs)')
            time.sleep(3)
        else:
            raise TimeoutError('Evaluation timed out; the app will be force-stopped')
    finally:
        print(f'Results: {results}', flush=True)
    if not report or report.get('status') != 'completed':
        raise RuntimeError(f'Evaluation failed: {report.get("error") if report else "no report"}')
    for record in report['cases']:
        entry = {key:record.get(key) for key in ('image_id','image_attached','first_output_ms','total_ms')}
        if str(record.get('image_id', '')).startswith('user_'):
            entry['output_saved_privately'] = True
        else:
            entry['output'] = record.get('output')
        print(json.dumps(entry,ensure_ascii=False), flush=True)
    print('Image inference executed. Compare outputs against fixtures; risk assessment is a later task.', flush=True)


def execute(arguments, apk):
    adb, info = device(arguments.serial)
    try:
        execute_connected(arguments, apk, adb, info)
    finally:
        # Cleanup also covers failed transfers and startup failures.
        subprocess.run(adb+['shell','am','force-stop',PACKAGE], stdout=subprocess.DEVNULL)
        if arguments.images:
            cleanup = app_shell(adb, ['rm', '-rf', 'files/eval-images'], text=True, capture_output=True)
            if cleanup.returncode:
                print('WARNING: could not remove private input copies; remove the evaluation app to clear them.', file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true', help='Prepare and build only; no device or model required')
    parser.add_argument('--skip-build', action='store_true', help='Reuse the previously built APK (for reruns only)')
    parser.add_argument('--model', default=os.environ.get('GEMMA_MODEL'))
    parser.add_argument('--candidate', choices=MODEL_FILES, default='gemma4')
    parser.add_argument('--fetch-model', action='store_true', help='Download the pinned public model to the host and verify its checksum')
    parser.add_argument('--language', choices=['en', 'ja'], default='en')
    parser.add_argument('--max-output-tokens', type=int, default=160)
    parser.add_argument('--with-ocr', action='store_true', help='Also supply synthetic fixed OCR blocks for the Japanese label')
    parser.add_argument('--only-image', action='append', choices=['red_circle','blue_bars','parcel_label','parcel_label_ja'], help='Restrict this run to a bundled fixture ID (repeatable)')
    parser.add_argument('--serial', default=os.environ.get('ANDROID_SERIAL'))
    parser.add_argument('--backend', choices=['gpu','cpu'], default='gpu')
    parser.add_argument('--images', help='Optional private directory of 1-10 real photos; never bundled into the APK')
    parser.add_argument('--repeats', type=int, default=1)
    parser.add_argument('--timeout', type=int, default=900, help='Maximum device run time in seconds')
    args = parser.parse_args()
    if not 1 <= args.repeats <= 10 or args.timeout <= 0 or not 16 <= args.max_output_tokens <= 512:
        parser.error('Use 1-10 repeats, a positive timeout and 16-512 output tokens')
    if args.skip_build and args.prepare:
        parser.error('--prepare and --skip-build cannot be combined')
    if not args.prepare:
        device(args.serial)
        if args.fetch_model:
            if args.model:
                parser.error('--fetch-model cannot be combined with --model or GEMMA_MODEL')
            args.model = str(fetch_model(args.candidate))
        if not args.model:
            parser.error('Provide --model or GEMMA_MODEL. See README for the pinned public models.')
    if args.skip_build:
        apk = APP/'build/app/outputs/flutter-apk/app-debug.apk'
        if not apk.is_file():
            raise ValueError('No previous APK. Run --prepare first.')
        info = json.loads((WORK/'build-info.json').read_text())
        if digest(apk) != info['apk_sha256'] or any(
            not (TOOL/name).is_file() or digest(TOOL/name) != expected
            for name, expected in (info['harness'] | info.get('fixtures', {})).items()
        ):
            raise ValueError('APK or evaluation source changed. Rebuild without --skip-build.')
    else:
        prepare()
        apk = build()
    if not args.prepare:
        execute(args, apk)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, TimeoutError, subprocess.CalledProcessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
