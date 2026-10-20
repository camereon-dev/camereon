#!/usr/bin/env python3
"""Seed the AI preview debug app with the pinned model over USB, without photos."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

TOOL = Path(__file__).resolve().parent
SPEC = json.loads((TOOL/'model.json').read_text())
PACKAGE = 'dev.camereon.camereon.demo.ai_preview'


def checksum(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(8*1024*1024):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--model', required=True)
    args = parser.parse_args()
    path = Path(args.model).expanduser()
    if not path.is_file() or path.stat().st_size != SPEC['size'] or checksum(path) != SPEC['sha256']:
        parser.error('Model must match model.json (size / SHA-256)')
    adb = ['adb', '-s', args.serial]
    api = int(subprocess.check_output(adb+['shell','getprop','ro.build.version.sdk'],text=True).strip())
    abis = subprocess.check_output(adb+['shell','getprop','ro.product.cpu.abilist'],text=True)
    if api < 30 or 'arm64-v8a' not in abis:
        parser.error('Android 11+ ARM64 is required')
    def private(arguments, **kwargs):
        return subprocess.run(adb+['shell','-T',shlex.join(['run-as',PACKAGE,*arguments])],**kwargs)
    if private(['id','-u'],capture_output=True).returncode:
        parser.error('Install the AI preview DEBUG APK first. Release APKs cannot use run-as.')
    remote = 'files/ai/models/'+SPEC['filename']
    current = private(['sha256sum',remote],text=True,capture_output=True)
    if current.returncode == 0 and current.stdout.startswith(SPEC['sha256']+' '):
        print('Preview model already verified.')
        return
    free = subprocess.check_output(adb+['shell','df','-k','/data'],text=True).splitlines()[-1].split()
    if int(free[3])*1024 < SPEC['size']+2*1024**3:
        parser.error('Not enough space for model and working cache')
    subprocess.run(adb+['shell','am','force-stop',PACKAGE],check=True)
    private(['mkdir','-p','files/ai/models'],check=True)
    print(f'Transferring {SPEC["size"]/1e9:.2f} GB into the AI preview only...',flush=True)
    with path.open('rb') as source:
        private(['sh','-c','cat > '+shlex.quote(remote+'.part')],stdin=source,check=True)
    result = private(['sha256sum',remote+'.part'],text=True,capture_output=True,check=True)
    if not result.stdout.startswith(SPEC['sha256']+' '):
        private(['rm','-f',remote+'.part'],check=True)
        parser.error('Device checksum mismatch')
    private(['mv',remote+'.part',remote],check=True)
    print('Preview model SHA-256 verified. No photos were copied.')


if __name__ == '__main__':
    main()
