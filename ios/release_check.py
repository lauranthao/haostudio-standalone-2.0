#!/usr/bin/env python3
"""HAo Studio 2.0 release gate (run at release time, do not ship-depend).

Verifies the manual release chain agrees before the download link goes
out — the chain preflight does NOT guard (2026-11-25, b49fix2 P2-67):
  repo version.json  <->  Info.plist (version/build)
  repo version.json  <->  README (version/build/size/download URL)
  repo version.json  <->  bitrise.yml artifact name (derived, not hardcoded)
  repo version.json  <->  shop's live manifest (--shop-manifest-url)
  repo version.json  <->  built IPA file (--ipa: size + md5 vs README)

Usage:
  python3 ios/release_check.py
  python3 ios/release_check.py --shop-manifest-url https://chen-hao-shop-production.up.railway.app/version.json
  python3 ios/release_check.py --ipa ios/HAoStudio.ipa --shop-manifest-url <url>

Exit code 0 = everything agrees; 1 = something disagrees (listed).
The repo-side checks run with no arguments; the shop/IPA checks only
run when their inputs are given, because the shop manifest is updated
by the deploy (after the build) and the IPA only exists after a build.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import sys
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent

failures = []


def check(label, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {label}" + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(label)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shop-manifest-url", default=None,
                    help="live shop version.json URL to compare against")
    ap.add_argument("--ipa", default=None,
                    help="built IPA path to verify (size + md5)")
    args = ap.parse_args()

    vj = json.loads((REPO / "version.json").read_text())
    pl = plistlib.load(open(REPO / "ios/HAoStudio/Info.plist", "rb"))
    readme = (REPO / "README.md").read_text()
    bitrise = (REPO / "bitrise.yml").read_text()
    version, build = vj.get("version"), vj.get("build")

    # Repo-side: version.json <-> Info.plist.
    check("version.json <-> Info.plist (version/build)",
          pl.get("CFBundleShortVersionString") == version
          and pl.get("CFBundleVersion") == str(build),
          f"plist {pl.get('CFBundleShortVersionString')}/{pl.get('CFBundleVersion')} "
          f"vs version.json {version}/{build}")

    # Repo-side: version.json <-> README.
    check("README names this version/build",
          f"**{version} build {build}**" in readme,
          f"looking for **{version} build {build}**")
    check("README IPA size matches version.json size",
          isinstance(vj.get("size"), int) and f"{vj['size']:,}" in readme,
          f"looking for {vj.get('size'):,}" if isinstance(vj.get("size"), int) else f"size={vj.get('size')!r}")
    check("README download URL matches version.json ipaUrl",
          isinstance(vj.get("ipaUrl"), str) and vj["ipaUrl"] in readme,
          str(vj.get("ipaUrl")))
    check("README version table has this version/build row",
          re.search(rf"\|\s*{re.escape(str(version))}\s*\|\s*{build}\s*\|", readme) is not None,
          f"looking for | {version} | {build} |")

    # Repo-side: Bitrise artifact name derived from version.json.
    check("Bitrise artifact name derived from version.json",
          "version.json" in bitrise
          and "HAoStudio-standalone-v$" in bitrise
          and not re.search(r"HAoStudio-standalone-v\d+\.\d+\.\d+\.zip", bitrise),
          "step must read version.json and use v$VERSION")

    # Release-time: shop manifest.
    if args.shop_manifest_url:
        try:
            with urllib.request.urlopen(args.shop_manifest_url, timeout=30) as r:
                shop = json.loads(r.read().decode("utf-8"))
            for key in ("version", "build", "ipaUrl", "size"):
                check(f"shop manifest {key} matches version.json",
                      shop.get(key) == vj.get(key),
                      f"shop={shop.get(key)!r} repo={vj.get(key)!r}")
        except Exception as e:
            check("shop manifest fetched", False, f"{args.shop_manifest_url}: {e}")

    # Release-time: built IPA.
    if args.ipa:
        ipa = pathlib.Path(args.ipa)
        check("IPA file exists", ipa.is_file(), str(ipa))
        if ipa.is_file():
            data = ipa.read_bytes()
            check("IPA size matches version.json size",
                  len(data) == vj.get("size"),
                  f"ipa={len(data)} version.json={vj.get('size')}")
            md5 = hashlib.md5(data).hexdigest()
            m = re.search(r"md5 `([0-9a-f]{32})`", readme)
            if m:
                check("IPA md5 matches README md5", md5 == m.group(1),
                      f"ipa={md5} readme={m.group(1)}")
            else:
                print("SKIP  IPA md5: no md5 in README to compare against")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {failures}")
        return 1
    print("RELEASE CHECK PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
