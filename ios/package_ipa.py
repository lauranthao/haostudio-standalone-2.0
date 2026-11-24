#!/usr/bin/env python3
"""Package an iOS .app bundle (inside a Payload dir) into an .ipa whose
zip entries are ordered for strict / sideloading-tool parsers.

Background (2026-11-24, build 37): LCSign failed to import an IPA
packaged with `zip -r HAoStudio.ipa Payload`. Its error: compatible
decompression finished but no usable shallow main bundle
(Payload/*.app/Info.plist) was found, and the local-header scan also
found nothing. The archive itself was valid (unzip -t clean, no data
descriptors, standard deflate) — but `zip -r` had placed
Payload/*.app/Info.plist at index 77 of 80, in the last 15 KB of a
14.5 MB file, after the 30 MB app binary. LCSign's shallow /
local-header scan never reaches it.

This script writes, in order: Payload/, Payload/*.app/,
Payload/*.app/Info.plist, Payload/*.app/PkgInfo, then everything else
— plain deflate, no extra fields, no data descriptors — so any
local-header-only walk finds the main bundle first.

Usage: python3 package_ipa.py <payload_dir> <output_ipa>
  payload_dir: directory containing exactly one .app bundle
  output_ipa: path of the .ipa to write
"""
import os
import sys
import zipfile


def main():
    payload_dir, out_path = sys.argv[1], sys.argv[2]
    apps = [d for d in sorted(os.listdir(payload_dir)) if d.endswith('.app')]
    assert len(apps) == 1, (
        f'expected exactly one .app in {payload_dir}, found {apps}')
    app = apps[0]
    app_root = os.path.join(payload_dir, app)

    entries = [(f'Payload/', None, True), (f'Payload/{app}/', None, True)]
    for root, dirs, files in os.walk(app_root):
        dirs.sort()
        for d in dirs:
            p = os.path.join(root, d)
            entries.append(('Payload/' + os.path.relpath(p, payload_dir)
                            + '/', p, True))
        for f in sorted(files):
            p = os.path.join(root, f)
            entries.append(('Payload/' + os.path.relpath(p, payload_dir),
                            p, False))

    def rank(e):
        name = e[0]
        if name == 'Payload/':
            return (0, '')
        if name == f'Payload/{app}/':
            return (1, '')
        if name == f'Payload/{app}/Info.plist':
            return (2, '')
        if name == f'Payload/{app}/PkgInfo':
            return (3, '')
        return (4, name)

    ordered = sorted(entries, key=rank)
    with zipfile.ZipFile(out_path, 'w', zipfile.ZIP_DEFLATED,
                         compresslevel=6) as z:
        for arcname, fs_path, is_dir in ordered:
            info = zipfile.ZipInfo(arcname)
            info.create_system = 0
            info.external_attr = 0
            info.extra = b''
            if is_dir:
                info.compress_type = zipfile.ZIP_STORED
                z.writestr(info, b'')
            else:
                # NOTE: ZipInfo defaults to STORED; set DEFLATED explicitly
                # or the archive balloons to the uncompressed size.
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(fs_path, 'rb') as f:
                    z.writestr(info, f.read())
    print(f'wrote {out_path}: {len(ordered)} entries, '
          f'Info.plist at index '
          f'{[e[0] for e in ordered].index(f"Payload/{app}/Info.plist")}')


if __name__ == '__main__':
    main()
