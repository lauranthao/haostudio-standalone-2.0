#!/usr/bin/env python3
"""HAo Studio 2.0 release gate (run at release time, do not ship-depend).

Verifies the manual release chain agrees before the download link goes
out — the chain preflight does NOT guard (2026-11-25, b49fix2 P2-67):
  repo version.json  <->  Info.plist (version/build)
  repo version.json  <->  README (version/build/size/download URL;
    version-table row must carry Bitrise #N + triggering commit
    for rows written after the rule landed — see P2-1 note below)
  repo version.json  <->  bitrise.yml artifact name (derived, not hardcoded)
  repo version.json  <->  shop's live manifest (--shop-manifest-url)
    (version/build/ipaUrl/size/sha256 AND changelog text)
    NOTE: the shop manifest is a MERGED manifest — besides the iOS
    fields above it also carries an apk* group (apkVersion, apkBuild,
    apkUrl/apkSize per flavor) that comes from the shop/Android side
    and is NOT in this repo's version.json (2026-11-26, b49-sweep10
    P2-16). Do NOT copy apk* fields into this repo's version.json,
    and do NOT expect this gate to check them: it only verifies the
    iOS fields listed above. If an apk* field ever goes stale live,
    that is a shop/Android-side problem, not a failure of this gate.
    NOTE: a missing "sha256" key and "" are the same state here
    (both mean "not yet filled"), so before release this check
    passes even though the live shop manifest carries NO sha256
    key at all. After filling sha256 at ship time, re-run with
    --release --shop-manifest-url ... : a filled repo value
    against an empty/missing shop value FAILS, which is the
    confirmation that the shop manifest actually carries the key
    (2026-11-26, b49-sweep11 release lane).
    NOTE: both live fetches in this script (shop manifest and
    live IPA download) retry transient transport failures up
    to 3 attempts with a 1s pause (2026-11-26, b49fix21
    D23-11: the manifest fetch failed with IncompleteRead on
    7 of 8 runs before the retry existed). Exhausting the
    attempts still FAILs the check — a retry is not a pass.
  repo version.json  <->  built IPA file (--ipa: size + md5 vs README
    + in-package version/build from Payload/*.app/Info.plist)
  repo version.json  <->  docs/index.html (GitHub Pages official
    site version line, :22)

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
  1. download the IPA built from the release commit (Bitrise
     deploy dir — NOT the live shop file; or hash the built file),
  2. sha256sum it,
  3. write the 64-hex value into version.json's "sha256" alongside
     "size" (and deploy so the shop manifest carries it too).
The hash must come from an IPA built from the release commit.
Never fill it from a hash measured off a live file whose provenance
is unknown: the shipped IPA carries no commit field, so a live hash
cannot prove which commit built it (2026-11-25, b49-sweep8 P2-24:
the live build-48 IPA's measured hash 0207b137... must NOT be
copied in — rebuild from the release commit and re-hash instead).
Before release the field is "" and plain runs SKIP the hash
comparisons (preflight check 4i-e likewise passes on empty). Pass
--release at ship time: an empty, missing or malformed sha256 then
FAILS, and the live shop IPA is downloaded and hashed against it.

UserDefaults key catalogue census (2026-11-26, b49-sweep11
release P2-1): the backup's key directory holds 98 distinct
keys — 75 from MigrationStore.mappings rows whose destination
is .userDefaults (117 mappings total, 75 distinct .userDefaults
keys; b49fix19 P2-1 added 5 collectionFile rows, so the
UserDefaults count is unchanged) + 23 more added in BackupEngine.userDefaultsKeyKinds()
(the S5 additions + b49fix2 P1-4 + b49fix4 P2-39 keys), zero
overlap. The "116 keys" figure in the sweep-9/10 summaries
was wrong (no source anywhere in the code) — do not reuse it;
re-count from these two sources if the catalogue ever changes.

Two-stage release flow (2026-11-26, b49-sweep12 release
P2-3): the build# + triggering-commit rule has NEVER been
executed — it only landed in a94f0cf (b49fix8-infra), and
the 0.0.2 release commit 42963ab carries neither a build
number nor a triggering commit, so 0.0.3 is the first
execution and the next sweep must verify its release commit
against README:100. The flow, in order:
  1. bump commit (version.json + Info.plist + preflight
     4b/4i + README, all four together) — this is the commit
     that TRIGGERS the Bitrise build;
  2. Bitrise build from that bump commit (workflow primary,
     branch main), download the IPA and verify the in-package
     version/build;
  3. release commit (README version-table row — carrying
     the Bitrise build number and the triggering commit, see
     README:100 — + version.json size/sha256 + a commit
     message naming the build number and the triggering
     commit's full 40-hex hash).
Precedent from 0.0.2 (same two-stage shape, before the rule
existed): bump commit 5b67e3c -> build -> release commit
42963ab. The triggering commit is the bump commit, never
the release commit itself — the release commit's own hash
does not exist yet when its message is written.

Ship-day checklist (2026-11-26, b49-sweep19 release P2-1:
the six steps used to live only in sweep reports, never in
one repo file — this header is now their canonical home, so
they cannot drift again; verify each against README:100):
  1. bump commit (version.json + Info.plist + preflight
     4b/4i + README, all four together) — this is the commit
     that TRIGGERS the Bitrise build; record its full 40-hex
     hash. version.json: version 0.0.3, build 49, ipaUrl
     v0.0.3, changelog in zh/tw/en. Info.plist: 0.0.3 / 49.
     preflight 4b/4i: 0.0.2 / 48 -> 0.0.3 / 49. README: :70
     current-version line, version-table 0.0.3 row, :72
     download link + size/md5 filled after the build.
  2. Bitrise build from the bump commit (workflow primary,
     branch main); take the ACTUAL dashboard build number N
     (never copy #30/#31 or the example number); download
     the IPA and verify the in-package version/build is
     0.0.3/49 — this script's --ipa check unpacks
     Payload/*.app/Info.plist and compares it against
     version.json (b49fix17, b49-sweep19 release P2-2), so
     the in-package check is gated, not manual-only.
  3. release commit: README version-table 0.0.3 row
     "| 0.0.3 | 49 | <date> | Bitrise #N (commit <bump commit
     full 40-hex hash>) ... |"; version.json size + sha256
     (sha256 from THIS build's IPA, sha256sum measured,
     never the live build-48 hash); commit message names
     the build number and the triggering commit's full
     40-hex hash. ALSO sync docs/index.html:22 to
     "当前版本 0.0.3（build 49）" (b49-sweep19 release
     P2-1: the 0.0.2 precedent 42963ab changed README +
     docs/index.html + version.json together, but the old
     checklist never mentioned it — the repo-side check
     below now guards it).
  4. shop deploy: redeploy so the live manifest carries
     the sha256 key and matches version.json.
  5. release_check all green: python3
     ios/release_check.py --release --shop-manifest-url
     <live manifest> --ipa <Bitrise-downloaded IPA>
     (incl. the "version table row carries Bitrise build #
     + triggering commit" gate), and preflight_check.py
     all green — only then send the link.
  6. 0.0.3 changelog trilingual: live manifest changelog
     verbatim equals version.json (this script compares).

0.0.3 changelog TODO (2026-11-26, b49-sweep12 release
P2-4; write at ship time into version.json's changelog in
all three languages AND the README version-table 0.0.3 row):
  - 弹幕字号设置同时适用于点播弹幕；未调过设置的用户点
    播弹幕由 16 变为默认 14 (round 9: LiveDanmakuSettings
    defaultFontSize 16 -> 14; so far only in a code comment
    at VodDanmakuLayer.swift:43-53).
  - 综合搜索页各 shelf 在种类收起/加载中/加载失败时显示
    footer，不再无声结束 (round 9 Music P2-1).
  - 每日推荐换歌时从已筛选备选回填至 20 首 (round 9
    Music P2-4).
Other round-9 changes are visual micro-adjustments or
internal behaviour — either leave them out or fold them
into one line: 「细节间距与备份行为微调」.
"""
import argparse
import hashlib
import http.client
import json
import pathlib
import plistlib
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile

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


# (2026-11-26, b49fix21 D23-11) Network fetch retry: the live
# shop manifest fetch failed with http.client.IncompleteRead on
# 7 of 8 runs in sweep 23 (Railway closes the connection
# mid-body in bursts; the manifest itself is fine — curl
# fetched it 4/4 in the same window, and a bare urlopen 9/13).
# A single urlopen then fails the whole gate and skips the
# changelog comparison and the live IPA hash, so a release-day
# all-green verdict depended on re-running until one attempt
# got lucky. Retry transient transport failures a couple of
# times with a short pause instead. Exhausting the attempts
# still raises, and the caller still FAILs the check — a retry
# is not a silent pass. The same helper covers both network
# points in this script (shop manifest + live IPA download).
FETCH_ATTEMPTS = 3
FETCH_RETRY_DELAY = 1.0
_FETCH_RETRYABLE = (http.client.IncompleteRead, urllib.error.URLError,
                    TimeoutError, ConnectionError)


def fetch_url_bytes(url, timeout):
    """GET url and return the whole body, retrying transient failures."""
    last = None
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                return r.read()
        except _FETCH_RETRYABLE as e:
            last = e
            if attempt < FETCH_ATTEMPTS:
                time.sleep(FETCH_RETRY_DELAY)
    raise last


def sha256_url(url, timeout=120):
    last = None
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        try:
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
        except _FETCH_RETRYABLE as e:
            last = e
            if attempt < FETCH_ATTEMPTS:
                time.sleep(FETCH_RETRY_DELAY)
    raise last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shop-manifest-url", default=None,
                    help="live shop version.json URL to compare against")
    ap.add_argument("--ipa", default=None,
                    help="IPA built from the release commit to verify "
                         "(size + md5 + sha256 + in-package version/build); "
                         "NEVER a file downloaded from the live shop")
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
    _row_m = re.search(rf"\|\s*{re.escape(str(version))}\s*\|\s*{build}\s*\|[^\n]*", readme)
    check("README version table has this version/build row",
          _row_m is not None,
          f"looking for | {version} | {build} |")
    # (2026-11-26, b49-sweep14 release P2-1) The build# +
    # triggering-commit rule (README:100, landed in a94f0cf)
    # requires the version-table row ITSELF to carry
    # "Bitrise #N (commit <full 40-hex hash>)". The old regex
    # only matched "| version | build |", so a row without the
    # build number passed the gate. Enforce it here — but
    # grandfather the 0.0.2 row: it was written before the rule
    # landed and has no Bitrise #N by design, so it is checked
    # on version/build only and must NOT fail this gate.
    if _row_m is not None and str(version) != "0.0.2":
        _row_text = _row_m.group(0)
        _has_build = re.search(r"Bitrise\s*#\d+", _row_text) is not None
        _has_hash = re.search(r"commit[^0-9a-f]{0,3}[0-9a-f]{40}\b", _row_text) is not None
        check("README version table row carries Bitrise build # + triggering commit",
              _has_build and _has_hash,
              f"row: {_row_text.strip()!r}"
              + ("" if _has_build else " — missing Bitrise #N")
              + ("" if _has_hash else " — missing 40-hex triggering commit"))

    # Repo-side: version.json <-> docs/index.html (GitHub Pages
    # official site, 2026-11-26, b49-sweep19 release P2-1). The
    # 0.0.2 release commit 42963ab changed docs/index.html:22
    # alongside README + version.json, but the six-item ship
    # checklist never mentioned it, so no gate caught a stale
    # site version. Same substring style as the README check.
    _site = (REPO / "docs/index.html").read_text()
    check("docs/index.html names this version/build",
          f"当前版本 {version}（build {build}）" in _site,
          f"looking for 当前版本 {version}（build {build}） in docs/index.html")

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
                  "empty — fill it from an IPA built from the release commit "
                  "(Bitrise download); never from a live shop file")
        else:
            skip("version.json sha256 (empty until release)",
                 "fill it at release time from an IPA built from the release "
                 "commit (Bitrise download); never from a live shop file")
    else:
        check("version.json sha256 is 64 lowercase hex", repo_sha_ok,
              str(repo_sha))

    # Release-time: shop manifest.
    if args.shop_manifest_url:
        try:
            # (2026-11-26, b49fix21 D23-11) fetch with retry —
            # see fetch_url_bytes; a transient IncompleteRead no
            # longer fails the whole gate on the first attempt.
            shop = json.loads(fetch_url_bytes(
                args.shop_manifest_url, timeout=30).decode("utf-8"))
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
            # changelog: the in-app update prompt shows the shop
            # manifest's release notes verbatim
            # (BackupUpdateLogic.promptContent takes
            # result.releaseNotes), so a drifted shop changelog
            # shows users stale text while every other check stays
            # green (2026-11-25, b49-sweep8 P1-2: the live manifest
            # still said the landscape player overflows after the
            # repo was fixed to "overflow is fixed"). Compare
            # verbatim, all three languages.
            repo_cl = vj.get("changelog")
            shop_cl = shop.get("changelog")
            if not isinstance(repo_cl, dict) or not isinstance(shop_cl, dict):
                check("shop manifest changelog matches version.json", False,
                      f"shop changelog={type(shop_cl).__name__} "
                      f"repo changelog={type(repo_cl).__name__}")
            else:
                langs = sorted(set(repo_cl) | set(shop_cl))
                diffs = [lang for lang in langs
                         if repo_cl.get(lang) != shop_cl.get(lang)]
                check("shop manifest changelog matches version.json",
                      not diffs,
                      ("languages differ: " + ", ".join(diffs)) if diffs
                      else "zh/tw/en verbatim")
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
                      f"version.json sha256 is empty; this IPA hashes to {ipa_sha} — "
                      "copy it into version.json ONLY if this file was built from the "
                      "release commit (Bitrise download); NEVER if it was downloaded "
                      "from the live shop (a live hash cannot prove which commit built it)")
            else:
                skip("IPA sha256 (version.json sha256 empty until release)",
                     f"this IPA hashes to {ipa_sha} — copy it into version.json at release time "
                     "ONLY if this file was built from the release commit (Bitrise download); "
                     "NEVER if it was downloaded from the live shop")

            # In-package version/build (2026-11-26, b49-sweep19
            # release P2-2): size/md5/sha256 only prove this file
            # is the file whose hashes were recorded — a build
            # from the wrong commit, hashed into README and
            # version.json, still passes them. Unpack
            # Payload/*.app/Info.plist and compare
            # CFBundleShortVersionString/CFBundleVersion against
            # version.json; this is the gate for checklist step
            # 2's "verify the in-package version/build", which
            # used to be manual-only.
            try:
                with zipfile.ZipFile(ipa) as _z:
                    _app_plist = next(
                        (n for n in _z.namelist()
                         if n.startswith("Payload/")
                         and n.endswith(".app/Info.plist")),
                        None)
                    if _app_plist is None:
                        check("IPA in-package version/build matches version.json",
                              False, "no Payload/*.app/Info.plist in IPA")
                    else:
                        _ipl = plistlib.loads(_z.read(_app_plist))
                        check("IPA in-package version/build matches version.json",
                              _ipl.get("CFBundleShortVersionString") == version
                              and _ipl.get("CFBundleVersion") == str(build),
                              f"in-package {_ipl.get('CFBundleShortVersionString')}/"
                              f"{_ipl.get('CFBundleVersion')} vs version.json "
                              f"{version}/{build}")
            except Exception as _e:
                check("IPA in-package version/build matches version.json",
                      False, f"could not read in-package Info.plist: {_e}")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {failures}")
        return 1
    print("RELEASE CHECK PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
