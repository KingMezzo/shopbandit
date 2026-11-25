"""Validate fork release tags before any signing or publication."""
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TAG = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(alpha|beta|rc)\.([1-9][0-9]*))?')


def validate(tag, pubspec, expected=None):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError('Expected vX.Y.Z or vX.Y.Z-(alpha|beta|rc).N')
    version = tag[1:]
    configured = re.search(r'^version:\s*([^+\s]+)\+[1-9][0-9]*\s*$', pubspec, re.MULTILINE)
    if not configured or configured[1] not in (version, '.'.join(match.group(1, 2, 3))):
        raise ValueError('Release tag does not match pubspec.yaml version')
    if expected is not None and expected != version:
        raise ValueError('Image version differs from caller tag')
    return version, bool(match[4])


def main():
    version, prerelease = validate(os.environ['GITHUB_REF_NAME'],
                                  (ROOT / 'app/pubspec.yaml').read_text(encoding='utf-8'),
                                  os.environ.get('EXPECTED_VERSION'))
    output = f'version={version}\nprerelease={str(prerelease).lower()}\n'
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as target:
            target.write(output)
    print(output, end='')


if __name__ == '__main__':
    main()
