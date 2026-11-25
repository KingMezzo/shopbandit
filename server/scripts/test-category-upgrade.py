#!/usr/bin/env python3
"""Reproduce a filled-v1 upgrade using two separate disposable Docker volumes.

Build the current server image first. No existing container/volume is accessed.
python server/scripts/test-category-upgrade.py --image shopbandit-categories:test
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--image', default='shopbandit-categories:test')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
suffix = uuid.uuid4().hex[:10]
legacy_image = f'shopbandit-category-legacy:{suffix}'
old, new = f'sb-category-old-{suffix}', f'sb-category-new-{suffix}'
vol_old, vol_new = old + '-data', new + '-data'


def docker(*params, capture=False):
    return subprocess.run(['docker', *params], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def wait_server(name):
    info = json.loads(docker('inspect', name, capture=True))[0]
    port = info['NetworkSettings']['Ports']['8090/tcp'][0]['HostPort']
    url = 'http://127.0.0.1:' + port
    for _ in range(150):
        try:
            with urllib.request.urlopen(url + '/api/health', timeout=1) as response:
                if response.status == 200:
                    return url
        except (OSError, urllib.error.URLError):
            time.sleep(0.2)
    docker('logs', name)
    raise RuntimeError('Test server did not become healthy')


try:
    with tempfile.TemporaryDirectory(prefix='shopbandit-category-test-') as tmp:
        context = pathlib.Path(tmp)
        (context / 'pb_hooks').mkdir()
        (context / 'pb_migrations').mkdir()
        shutil.copy(root / 'Dockerfile', context / 'Dockerfile')
        # Deliberately frozen original schema and hooks, not the new feature.
        shutil.copy(root / 'pb_migrations/1760000000_shopbandit_init.js', context / 'pb_migrations')
        for file in ('main.pb.js', 'shopbandit.js'):
            shutil.copy(root / 'pb_hooks' / file, context / 'pb_hooks')
        docker('build', '-q', '-t', legacy_image, str(context))
        for volume in (vol_old, vol_new):
            docker('volume', 'create', volume)
        docker('run', '-d', '--name', old, '-p', '127.0.0.1::8090',
               '-v', vol_old + ':/pb/pb_data', legacy_image)
        fixture = context / 'fixture.json'
        test = root / 'scripts/category-test.py'
        subprocess.run([sys.executable, str(test), wait_server(old), '--prepare-legacy', str(fixture)], check=True)
        docker('stop', old)
        # Copy only the stopped throw-away volume; source stays read-only.
        docker('run', '--rm', '--user', '0', '--entrypoint', '/bin/sh',
               '-v', vol_old + ':/source:ro', '-v', vol_new + ':/target',
               legacy_image, '-c', 'cp -a /source/. /target/')
        docker('run', '-d', '--name', new, '-p', '127.0.0.1::8090',
               '-v', vol_new + ':/pb/pb_data', args.image)
        url = wait_server(new)
        subprocess.run([sys.executable, str(test), url, '--verify-legacy', str(fixture)], check=True)
        docker('restart', new)
        url = wait_server(new)
        subprocess.run([sys.executable, str(test), url, '--verify-legacy', str(fixture)], check=True)
        print('UPGRADE + RESTART TEST PASSED', flush=True)
finally:
    # Only names generated in this invocation are ever removed.
    for name in (new, old):
        subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for volume in (vol_new, vol_old):
        subprocess.run(['docker', 'volume', 'rm', volume], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['docker', 'image', 'rm', legacy_image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
