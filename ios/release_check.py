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
  python3 ios/release_check.py --release
  python3 ios/release_check.py --shop-manifest-url https://chen-hao-shop-production.up.railway.app/version.json
  python3 ios/release_check.py --ipa ios/HAoStudio.ipa --shop-manifest-url <url>

Exit code 0 = everything agrees; 1 = something disagrees (listed).
The repo-side checks run with no arguments; the shop/IPA checks only
run when their inputs are given, because the shop manifest is updated
by the deploy (after the build) and the IPA only exists after a build.

SHA-256 (2026-11-25, b49fix3 P1-12): the app verifies a downloaded
IPA against version.json's sha256 (UpdateManifest.asSHA256), so the
field must be filled at release time or the check is dead code. The
release step, in the same release commit that fills size:
  1. download the shipped IPA (or hash the built file),
  2. sha256sum it,
  3. write the 64-hex value into version.json's "sha256" alongside
     "size" (and deploy so the shop manifest carries it too).
Before release the field is "" and plain runs SKIP the hash
comparisons (preflight check 4i-e likewise passes on empty). Pass
--release at ship time: an empty, missing or malformed sha256 then
FAILS, and the live shop IPA is downloaded and hashed against it.
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


def skip(label, detail=""):
    print(f"SKIP  {label}" + (f": {detail}" if detail else ""))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_url(url, timeout=120):
    h = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(url, timeout=timeout) as r:
        while True:
            chunk = r.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            h.update(chunk)
    return h.hexdigest(), size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shop-manifest-url", default=None,
                    help="live shop version.json URL to compare against")
    ap.add_argument("--ipa", default=None,
                    help="built IPA path to verify (size + md5 + sha256)")
    ap.add_argument("--release", action="store_true",
                    help="release-time enforcement: an empty, missing or "
                         "malformed version.json sha256 FAILS instead of "
                         "being skipped")
    args = ap.parse_args()

    vj = json.loads((REPO / "version.json").read_text())
    pl = plistlib.load(open(REPO / "ios/HAoStudio/Info.plist", "rb"))
    readme = (REPO / "README.md").read_text()
    bitrise = (REPO / "bitrise.yml").read_text()
    version, build = vj.get("version"), vj.get("build")
    repo_sha = vj.get("sha256", None)
    repo_sha_ok = (isinstance(repo_sha, str)
                   and re.fullmatch(r"[0-9a-f]{64}", repo_sha) is not None)

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

    # Repo-side: version.json sha256 field. Empty until release time;
    # plain runs only require the field to exist and, when filled,
    # to be 64 lowercase hex. --release requires it filled.
    if repo_sha is None:
        check("version.json sha256 field present", False,
              "no 'sha256' key in version.json")
    elif repo_sha == "":
        if args.release:
            check("version.json sha256 filled (--release)", False,
                  "empty — fill it from the shipped IPA before shipping")
        else:
            skip("version.json sha256 (empty until release)",
                 "fill it from the shipped IPA at release time")
    else:
        check("version.json sha256 is 64 lowercase hex", repo_sha_ok,
              str(repo_sha))

    # Release-time: shop manifest.
    if args.shop_manifest_url:
        try:
            with urllib.request.urlopen(args.shop_manifest_url, timeout=30) as r:
                shop = json.loads(r.read().decode("utf-8"))
            for key in ("version", "build", "ipaUrl", "size"):
                check(f"shop manifest {key} matches version.json",
                      shop.get(key) == vj.get(key),
                      f"shop={shop.get(key)!r} repo={vj.get(key)!r}")
            # sha256: a missing key and "" are the same state ("not
            # yet filled at release time"), so normalize both; a
            # filled repo value against an empty shop value is a
            # real deploy-sync failure and must FAIL.
            check("shop manifest sha256 matches version.json",
                  (shop.get("sha256") or "") == (vj.get("sha256") or ""),
                  f"shop={shop.get('sha256')!r} repo={vj.get('sha256')!r}")
        except Exception as e:
            check("shop manifest fetched", False, f"{args.shop_manifest_url}: {e}")
            shop = None

        # Release-time: hash the LIVE shop IPA against version.json.
        # This is the check that makes sha256 real: the app verifies
        # the file it downloads, so the manifest must match the file
        # actually served, not just the file that was built.
        if shop is not None:
            live_url = shop.get("ipaUrl") or vj.get("ipaUrl")
            if not isinstance(live_url, str) or not live_url:
                check("live IPA URL present", False, f"ipaUrl={live_url!r}")
            elif not repo_sha_ok:
                skip("live IPA sha256 (version.json sha256 empty until release)",
                     f"would hash {live_url}")
            else:
                try:
                    live_sha, live_size = sha256_url(live_url)
                    check("live IPA size matches version.json size",
                          live_size == vj.get("size"),
                          f"live={live_size} version.json={vj.get('size')}")
                    check("live IPA sha256 matches version.json sha256",
                          live_sha == repo_sha,
                          f"live={live_sha} repo={repo_sha}")
                except Exception as e:
                    check("live IPA downloaded and hashed", False,
                          f"{live_url}: {e}")

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
            # sha256 is what the app verifies against, so the built
            # file's hash is the value the release step writes into
            # version.json. Compare when the field is filled; when
            # it is empty, print the hash to copy in (FAIL only
            # under --release, which runs at ship time).
            ipa_sha = sha256_file(ipa)
            if repo_sha_ok:
                check("IPA sha256 matches version.json sha256",
                      ipa_sha == repo_sha,
                      f"ipa={ipa_sha} repo={repo_sha}")
            elif args.release:
                check("IPA sha256 recorded in version.json (--release)", False,
                      f"version.json sha256 is empty; this IPA hashes to {ipa_sha}")
            else:
                skip("IPA sha256 (version.json sha256 empty until release)",
                     f"this IPA hashes to {ipa_sha} — copy it into version.json at release time")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {failures}")
        return 1
    print("RELEASE CHECK PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
