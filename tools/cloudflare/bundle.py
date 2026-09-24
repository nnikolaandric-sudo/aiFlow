#!/usr/bin/env python3
"""Bundle official, pinned Cloudflare binaries at build time; users install nothing."""
import hashlib, json, os, pathlib, shutil, subprocess, sys, tarfile, urllib.request
root = pathlib.Path(__file__).resolve().parents[2]
manifest = json.loads((root / 'tools/cloudflare/manifest.json').read_text())
contents = pathlib.Path(sys.argv[1]).resolve()
cache = root / 'build/cloudflared' / manifest['version']
cache.mkdir(parents=True, exist_ok=True)
out = contents / 'Helpers'
out.mkdir(parents=True, exist_ok=True)
for arch in set(os.environ.get('ARCHS', 'arm64').split()):
    asset = manifest['assets'][arch]
    archive = cache / asset['name']
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != asset['sha256']:
        url = f"https://github.com/cloudflare/cloudflared/releases/download/{manifest['version']}/{asset['name']}"
        temporary = archive.with_suffix('.download')
        with urllib.request.urlopen(url, timeout=90) as response, temporary.open('wb') as target:
            shutil.copyfileobj(response, target)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != asset['sha256']:
            temporary.unlink()
            raise SystemExit('Cloudflared archive checksum mismatch')
        temporary.replace(archive)
    target = out / f'cloudflared-{arch}'
    with tarfile.open(archive) as package:
        entries = [member for member in package.getmembers() if pathlib.PurePosixPath(member.name).name == 'cloudflared']
        if len(entries) != 1 or not entries[0].isfile() or entries[0].size > 200_000_000:
            raise SystemExit('Unexpected cloudflared archive layout')
        with package.extractfile(entries[0]) as source, target.open('wb') as destination:
            shutil.copyfileobj(source, destination)
    target.chmod(0o755)
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
    args = ['codesign', '--force', '--sign', identity]
    if identity != '-': args += ['--options', 'runtime']
    subprocess.run(args + [str(target)], check=True)
    print(f"Bundled cloudflared {manifest['version']} ({arch}), verified SHA-256")
resources = contents / 'Resources'
shutil.copytree(root / 'share-server/public', resources / 'SecureShareWeb', dirs_exist_ok=True)
license_file = cache / 'LICENSE'
if not license_file.exists():
    url = f"https://raw.githubusercontent.com/cloudflare/cloudflared/{manifest['version']}/LICENSE"
    with urllib.request.urlopen(url, timeout=30) as response:
        license_file.write_bytes(response.read())
shutil.copyfile(license_file, resources / 'Cloudflared-LICENSE.txt')
(resources / 'Cloudflared-NOTICE.txt').write_text(
    f"cloudflared {manifest['version']}\nCopyright Cloudflare, Inc.\n"
    "https://github.com/cloudflare/cloudflared\nApache License 2.0; see Cloudflared-LICENSE.txt.\n"
    "Bundled executable is re-signed as part of FinderFlow distribution.\n")
