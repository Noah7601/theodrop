#!/usr/bin/env bash
# Downloads the pinned portable conversion engines (rhwp, 7zip) for one runtime.
# Mirrors build/fetch-portable-engines.ps1 without PowerShell.
#
# Usage: build/fetch-portable-engines.sh <runtime> <destination> [engine ...]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="${1:?runtime is required}"
destination="${2:?destination is required}"
shift 2
engines=("$@")
if [ ${#engines[@]} -eq 0 ]; then engines=(rhwp 7zip); fi

python3 - "$root/src/Filee.Engines/Infrastructure/engines.json" "$runtime" "$destination" "$root/build/.cache/portable-downloads" "${engines[@]}" <<'PY'
import hashlib, json, os, shutil, subprocess, sys, tarfile, urllib.request, uuid

manifest_path, runtime, destination, cache = sys.argv[1:5]
names = sys.argv[5:]
platforms = json.load(open(manifest_path, encoding='utf-8'))['platforms']
if runtime not in platforms:
    sys.exit(f'Unknown runtime: {runtime}')
components = platforms[runtime]['components']
os.makedirs(cache, exist_ok=True)
os.makedirs(destination, exist_ok=True)
destination = os.path.realpath(destination)


def digest(path):
    hasher = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            hasher.update(block)
    return hasher.hexdigest().lower()


for name in names:
    component = components.get(name)
    if not component or len(component.get('sha256', '')) != 64:
        sys.exit(f'A pinned {name} download is missing for {runtime}.')
    expected = component['sha256'].lower()
    target = os.path.join(destination, name)
    if os.path.exists(target):
        sys.exit(f'Engine destination already exists: {target}. Use a fresh publish folder.')
    archive = os.path.join(cache, f"{expected}.{component['kind']}")
    if not os.path.exists(archive):
        partial = f'{archive}.{uuid.uuid4().hex}.partial'
        urllib.request.urlretrieve(component['url'], partial)
        if digest(partial) != expected:
            os.remove(partial)
            sys.exit(f'Checksum mismatch for {name} ({runtime}).')
        os.replace(partial, archive)
    if digest(archive) != expected:
        sys.exit(f'Cached engine checksum mismatch: {archive}')
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        for member in members:
            path = member.name
            if path.startswith(('/', '\\')) or ':' in path or any(part == '..' for part in path.replace('\\', '/').split('/')):
                sys.exit(f'Unsafe archive member: {path}')
            # These bundles contain only files and directories; reject links and special entries.
            if not (member.isfile() or member.isdir()):
                sys.exit(f'Unsupported archive entry (links and special files are not allowed): {path}')
        stage = os.path.join(cache, f'extract-{uuid.uuid4().hex}')
        os.makedirs(stage)
        bundle.extractall(stage)
    children = os.listdir(stage)
    payload = os.path.join(stage, children[0]) if len(children) == 1 and os.path.isdir(os.path.join(stage, children[0])) else stage
    executable = 'rhwp' if name == 'rhwp' else '7zz'
    if not os.path.isfile(os.path.join(payload, executable)):
        sys.exit(f'{executable} was not found at the expected location in {archive}')
    shutil.move(payload, target)
    os.chmod(os.path.join(target, executable), 0o755)
    shutil.rmtree(stage, ignore_errors=True)
    print(f'{name} ready for {runtime}')
PY
