#!/usr/bin/env python3
"""HAo Studio 2.0 preflight checks for ios/ (run, do not ship-depend).

Rewritten for the Swift-native 2.0 foundation slice (no old web shell,
no removed metadata service, no lyrics extension, no Podfile yet). Checks, in order:

  1. every file the pbxproj references exists on disk — EXCEPT the 18
     libmpv xcframeworks, which are downloaded at build time by
     codemagic.yaml and are therefore checked as "expected at build
     time" (codemagic download step + FRAMEWORK_SEARCH_PATHS must exist
     instead);
  2. pbxproj has exactly one target, no stale references to deleted
     files (old Swift names, web/, old metadata config, old lyrics target);
  3. Assets exist (AppIcon + Logo, with the pinned md5s);
  4. Info.plist key values (display name, bundle version, background
     audio, launch storyboard, URL scheme, NO scene delegate — the 2.0
     app is SwiftUI @main and must not declare a scene delegate class);
  5. Swift brace/paren balance + forbidden leftovers (old web shell,
     old metadata service, old frontend entry, hardcoded purple) in the new sources;
  6. the 13 foundation Swift files are all in the Sources build phase;
  7. codemagic.yaml parses, has the libmpv download step, and has NO
     web-sync / metadata-key-inject step;
  8. build settings carried over from the old project (bundle id,
     deployment target 17.0 (chen 2026-11-23), Swift 5.0, device family,
     entitlements, app icon name, libmpv framework search path);
  9. splash spec values present in SplashView.swift (timings + geometry);
 10. theme system: 4 themes x light/dark = 8 palettes, no purple hex;
 11. LX scripts: no cleartext http:// API URL (ATS — literals + decoded
     _u obfuscated strings), with startsWith validators, comments,
     @see links and Referer values allowlisted by shape.
 11b. Swift side: no cleartext http:// request URL literal (ATS),
     with hasPrefix validators, http→https upgraders and // comments
     allowlisted by shape; Tests excluded (fixtures use example.invalid,
     emby.local and 192.168.x by design).
 4i also validates version.json ipaUrl/size/trilingual changelog;
 4m checks the Bitrise artifact name is derived from version.json;
 5 is a floor (162) instead of an exact count; 5e detects (not bans)
 concurrency; 6 is scoped to the app Sources phase (...55); 6b checks
 test-target membership/imports; 7 and 4k fail instead of passing
 vacuously when their parser/pattern is absent.

Exit code 0 = all checks pass; 1 = something failed (listed at the end).
Run: python3 ios/preflight_check.py
"""
import hashlib
import json
import pathlib
import plistlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
IOS = REPO / "ios"
PBX = IOS / "HAoStudio.xcodeproj/project.pbxproj"
APP_DIR = IOS / "HAoStudio"

# Forbidden needles, assembled from fragments and never written as
# literals in this file: this script enforces the repo-wide ban on the
# old web shell / removed metadata service / deleted source files, and
# a literal occurrence here would itself trip the repo-wide grep for
# them. The fragments below are the banned strings, split in two.
_N_WEBVIEW = "WK" + "WebView"
_N_META = "TM" + "DB"
_N_META_LOWER = "tm" + "db"
_N_FRONTEND = "app" + ".js"
_N_VIEWCTRL = "View" + "Controller"
_N_SCENEDEL = "Scene" + "Delegate"
_N_APPDEL = "App" + "Delegate"
_N_LYRICS = "HAoStudio" + "Lyrics"
_N_META_CFG = _N_META_LOWER + "-config"
_N_META_KEY = _N_META + "_API_KEY"

failures = []


def check(label, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {label}" + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(label)


pbx = PBX.read_text()

# Group-aware path resolution for PBXFileReference entries: a ref's path
# is relative to its parent group, and groups nest (HAoStudio group path
# = "HAoStudio", Theme group path = "Theme", ...). The naive check of
# ios/<path> passed the BROKEN doubled paths (Theme/Theme/...) in
# build #11 and failed the fixed bare paths — so every ref check below
# resolves through the group chain. (2026-11-23: doubled-path fix.)
_groups = {}
for m in re.finditer(r"(\w+)(?: /\* [^*]+ \*/)? = \{isa = PBXGroup; children = \((.*?)\);(?: name = [^;]+;)?(?: path = ([^;]+);)? sourceTree = \"<group>\"; \};", pbx, re.S):
    _groups[m.group(1)] = (m.group(3) or "", re.findall(r"(\w+) /\*", m.group(2)))
_parent = {child: gid for gid, (_, kids) in _groups.items() for child in kids}
def _resolve(rid, fname):
    parts, cur, seen = [fname], _parent.get(rid), set()
    while cur and cur not in seen:  # cycle guard: a bad parse must not hang
        seen.add(cur)
        pth, _ = _groups[cur]
        if pth:
            parts.append(pth)
        cur = _parent.get(cur)
    return "/".join(reversed(parts))

# --- 1. pbxproj file refs exist (libmpv excepted: build-time download) ---
missing = []
libmpv_refs = []
for m in re.finditer(
    r"([0-9A-F]{24}) /\* ([^*]+) \*/ = \{isa = PBXFileReference;.*?path = ([^;]+); sourceTree = \"<group>\";",
    pbx,
):
    _oid, name, path = m.groups()
    path = path.strip()
    name = name.strip()
    if path.endswith(".xcframework"):
        libmpv_refs.append(name)
        continue
    if not (IOS / _resolve(_oid, path)).exists():
        missing.append((name, path))
check("1. pbxproj file refs exist", not missing, str(missing) if missing else "all repo-tracked refs resolve")
check("1b. libmpv xcframework refs (18, build-time)", len(libmpv_refs) == 18, f"{len(libmpv_refs)} refs")

# --- 2. one target, no stale refs ---------------------------------------
targets = re.findall(r"productType = \"com\.apple\.product-type\.application\"", pbx)
check("2. exactly one app target", len(targets) == 1, f"{len(targets)} app targets")
# Stale names from the old (pre-2.0) Swift app: any reference to them
# must be gone. S3 reintroduces PlayerKernel / IJKPlayerBackend /
# MpvPlayerBackend / AVPlayerBackend as NEW files (A leg), so those
# four names are NOT stale anymore — checks 1 and 6 verify they
# resolve to real files in the Sources phase. Do not re-add them
# here unless the S3 files are deleted first.
stale = [s for s in [_N_LYRICS, _N_VIEWCTRL + ".swift", _N_APPDEL + ".swift",
                     _N_SCENEDEL + ".swift", "NativePlayer" + "ViewController",
                     "updater" + ".swift",
                     _N_META_CFG, "Lyrics" + "LiveActivity",
                     "Podfile"]
         if s in pbx]
check("2b. no stale old-file references in pbxproj", not stale, str(stale))

# --- 3. assets -----------------------------------------------------------
for rel, md5 in [("Assets.xcassets/AppIcon.appiconset/icon-1024.png",
                  "d61d06f7809802145f456a91fc9b6035"),
                 ("Assets.xcassets/Logo.imageset/logo.png",
                  "887bad72295b82bdcac2b0686ee90d99")]:
    p = APP_DIR / rel
    ok = p.exists() and hashlib.md5(p.read_bytes()).hexdigest() == md5
    check(f"3. asset {rel.split('/')[-1]} md5", ok, md5)
for cj in ["Assets.xcassets/AppIcon.appiconset/Contents.json",
           "Assets.xcassets/Logo.imageset/Contents.json"]:
    d = json.loads((APP_DIR / cj).read_text())
    imgs = [i.get("filename") for i in d.get("images", []) if i.get("filename")]
    ok = all((APP_DIR / cj).parent.joinpath(f).exists() for f in imgs)
    check(f"3b. {cj.split('/')[-2]} images exist", ok, str(imgs))

# --- 4. Info.plist --------------------------------------------------------
pl = plistlib.load(open(APP_DIR / "Info.plist", "rb"))
check("4. displayName HAo Studio", pl.get("CFBundleDisplayName") == "HAo Studio")
check("4b. bundle version 0.0.2 / build 48 (release)",
      pl.get("CFBundleShortVersionString") == "0.0.2" and pl.get("CFBundleVersion") == "48",
      f"{pl.get('CFBundleShortVersionString')} / {pl.get('CFBundleVersion')}")
check("4c. background audio mode", pl.get("UIBackgroundModes") == ["audio"])
check("4d. launch storyboard", pl.get("UILaunchStoryboardName") == "LaunchScreen")
check("4e. URL scheme haostudio",
      any("haostudio" in (u.get("CFBundleURLSchemes") or [])
          for u in pl.get("CFBundleURLTypes", [])))
check("4f. NO scene delegate / scene manifest (SwiftUI @main)",
      "UIApplicationSceneManifest" not in pl and _N_SCENEDEL not in (APP_DIR / "Info.plist").read_text())
check("4g. arm64 only", pl.get("UIRequiredDeviceCapabilities") == ["arm64"])
check("4h. entitlements file is intentionally empty",
      plistlib.load(open(APP_DIR / "HAoStudio.entitlements", "rb")) == {})
# --- 4i. version.json aligned with the bundle (S0) -----------------------
vj = json.loads((REPO / "version.json").read_text())
check("4i. version.json aligned (0.0.2 / build 48 / minOs 17.0)",
      vj.get("version") == "0.0.2" and vj.get("build") == 48 and vj.get("minOs") == "17.0",
      f"{vj.get('version')} / build {vj.get('build')} / minOs {vj.get('minOs')}")
# (2026-11-25, b49fix2 P2-65): 4i used to check only version/build/
# minOs — a typo'd ipaUrl passed and the app offered an update that
# 404s, and a missing size or changelog passed silently. Validate
# the release fields too: ipaUrl must be the shop URL for this
# version's IPA, size must be a positive byte count, and the
# changelog must exist in all three languages (zh/tw/en) and name
# this version.
_v = vj.get("version")
check("4i-b. version.json ipaUrl points at this version's IPA",
      isinstance(vj.get("ipaUrl"), str)
      and vj["ipaUrl"] == f"https://chen-hao-shop-production.up.railway.app/HAoStudio-standalone-v{_v}.ipa",
      str(vj.get("ipaUrl")))
check("4i-c. version.json size is a positive byte count",
      isinstance(vj.get("size"), int) and vj["size"] > 0,
      str(vj.get("size")))
_cl = vj.get("changelog") or {}
check("4i-d. version.json changelog is trilingual and names this version",
      isinstance(_cl, dict) and all(
          isinstance(_cl.get(k), str) and _cl[k].startswith(f"v{_v}")
          for k in ("zh", "tw", "en")),
      f"keys: {sorted(_cl.keys()) if isinstance(_cl, dict) else type(_cl).__name__}")
# (2026-11-25, b49fix3 P1-12; wording fixed b49fix13, b49-sweep15
# release P2-1): sha256 is written at release time (download the
# IPA built from the release commit (Bitrise deploy dir — NOT the
# live shop file), sha256sum it, write it into version.json
# alongside size, in the same release commit) and is what the app
# (UpdateManifest.asSHA256). Before release the field is empty
# and that must NOT fail preflight; a non-empty value must be
# exactly 64 lowercase hex, and the field must exist at all.
_sh = vj.get("sha256", None)
check("4i-e. version.json sha256 empty until release, else 64 lowercase hex",
      _sh is not None and (_sh == "" or (isinstance(_sh, str)
          and re.fullmatch(r"[0-9a-f]{64}", _sh) is not None)),
      f"sha256={_sh!r}")
# --- 4m. Bitrise artifact name derived from version.json ---------------
# (2026-11-25, b49fix2 P1-42/P2-65): bitrise.yml hardcoded
# HAoStudio-standalone-v0.0.2.zip, so the 0.0.3 build would have
# shipped a misnamed artifact. The step must now derive the name
# from version.json; a hardcoded vX.Y.Z name fails this check.
_bit = (REPO / "bitrise.yml").read_text()
check("4m. Bitrise artifact name derived from version.json, not hardcoded",
      "version.json" in _bit
      and "HAoStudio-standalone-v$" in _bit
      and not re.search(r"HAoStudio-standalone-v\d+\.\d+\.\d+\.zip", _bit),
      "step must read version.json and use v$VERSION")
# --- 4j. project.pbxproj parses: braces/parens balanced ------------------
# (2026-11-23: Codemagic build #10 failed with "project is damaged, parse
# error" — 4 XCBuildConfiguration lines were missing the closing brace of
# buildSettings. Preflight passed then because it never checked pbxproj.)
pbx = (REPO / "ios/HAoStudio.xcodeproj/project.pbxproj").read_text()
check("4j. project.pbxproj braces/parens balanced",
      pbx.count("{") == pbx.count("}") and pbx.count("(") == pbx.count(")"),
      f"{{ {pbx.count('{')} {pbx.count('}')} ( {pbx.count('(')} {pbx.count(')')}")
_cfg_lines = [ln for ln in pbx.splitlines()
              if "XCBuildConfiguration; buildSettings = {" in ln]
check("4k. every XCBuildConfiguration closes buildSettings before name",
      # (2026-11-25, b49fix2 P2-63): the old all(...) over matching
      # lines was vacuously true if the pattern ever disappeared
      # (6 lines match today) — assert the pattern exists first.
      len(_cfg_lines) > 0 and all("}; name = " in ln for ln in _cfg_lines),
      f"{len(_cfg_lines)} config lines")
# --- 4l. every Swift file ref resolves to a real file on disk ------------
# (2026-11-23: Codemagic build #11 failed "Build input files cannot be
# found" — 10 scaffold refs carried 'Theme/Theme/...' doubled paths
# because the parent group already supplies the directory. Uses the
# group-aware _resolve defined above check 1.)
_missing = []
for m in re.finditer(r"(\w+) /\* ([^*]+) \*/ = \{isa = PBXFileReference; lastKnownFileType = sourcecode\.swift; path = ([^;]+); sourceTree = \"<group>\"; \};", pbx):
    resolved = _resolve(m.group(1), m.group(3))
    if not (REPO / "ios" / resolved).is_file():
        _missing.append(f"{m.group(2)} -> {resolved}")
check("4l. every Swift file ref resolves to a file on disk", not _missing,
      f"{len(_missing)} missing: {_missing[:3]}" if _missing else "all resolve")

# --- 5. Swift sources: balance + forbidden leftovers ----------------------
swift_files = sorted(APP_DIR.rglob("*.swift"))
# (2026-11-25, b49fix2 P2-66): the exact count was brittle — any
# legitimate file add failed the gate until the hardcoded number was
# bumped, and a delete-plus-add pair kept the count at 162 while
# losing a file. The gate is now a floor: files may be added freely
# (check 6 requires every disk file to be in the app Sources phase,
# check 1 requires every pbxproj ref to resolve); dropping below the
# floor means a file was lost. The 162 is the count as of 2026-11-25
# (157 + HaoImagePolicy.swift + HaoImageLoader.swift [b36-item10-leg6:
# shared image loader] + LiveGestures.swift [b37-L3: live drag
# gestures] + DouyinSigner.swift [b37-L5: A-Bogus port] +
# GestureMath.swift [b37-fix: pure gesture math split out of
# VodGestures/LiveGestures for AppCore]). Bump the floor only when
# files are deliberately deleted, with a comment saying why.
check("5. Swift file count (floor 162 — adds are fine, losses fail)",
      len(swift_files) >= 162,
      f"{len(swift_files)}: {[f.name for f in swift_files]}")
for f in swift_files:
    s = f.read_text()
    ok = s.count("{") == s.count("}") and s.count("(") == s.count(")")
    check(f"5b. braces/parens {f.relative_to(APP_DIR)}", ok,
          f"{{ {s.count('{')} {s.count('}')} ( {s.count('(')} {s.count(')')}")

joined = "\n".join(f.read_text() for f in swift_files)
# Strip comments first: headers legitimately NAME the removed files
# (e.g. an old controller file as a spec citation); what is forbidden
# is actual CODE referencing them.
code_only = re.sub(r"//.*", "", joined)
code_only = re.sub(r"/\*.*?\*/", "", code_only, flags=re.DOTALL)
# 5c allowlist (b45-h, coordinator decision 2026-11-25): the system
# share sheet is the ONE allowed UIKit view controller — the update
# flow auto-presents it after an IPA download (Coda §9.6, download
# -> share -> signing tool). The three exact type names are stripped
# (longest first) before the substring check below; any other old
# UIKit controller still fails. The tokens are
# assembled from fragments so this file never holds the banned
# literal itself (see the header note on fragments).
_SHARE_VC = "UIActivity" + "View" + "Controller"
_UI_VC_REP = "UI" + "View" + "Controller" + "Representable"
_UI_VC = "UI" + "View" + "Controller"
for _allowed in [_SHARE_VC, _UI_VC_REP, _UI_VC]:
    code_only = code_only.replace(_allowed, "")
for needle, label in [(_N_WEBVIEW, "old web shell"), (_N_META, "removed metadata service"),
                      (_N_META_LOWER, "removed metadata service (lowercase)"),
                      (_N_FRONTEND, "old frontend entry"), (_N_VIEWCTRL, "old controller file"),
                      (_N_SCENEDEL, "scene delegate"), (_N_APPDEL, "app delegate")]:
    check(f"5c. no {label} in Swift sources (code)", needle not in code_only)
# No purple hex anywhere in the theme file (iron law 1): a colour counts
# as purple when red AND blue are both high while green is far lower.
def is_purple(hex6):
    r, g, b = (int(hex6[i:i + 2], 16) for i in (0, 2, 4))
    return r > 80 and b > 80 and g < min(r, b) - 40
theme_src = (APP_DIR / "Theme/HaoTheme.swift").read_text()
hexes = re.findall(r"0x([0-9A-Fa-f]{6})", theme_src)
purples = [h for h in hexes if is_purple(h)]
check("5d. no purple hex in HaoTheme.swift", not purples,
      f"{len(hexes)} hex literals, purple: {purples or 'none'}")

# Deployment target is iOS 17.0 (chen 2026-11-23): iOS 16+ APIs
# (NavigationStack, .symbolVariant, .scrollContentBackground) are
# available and need no guard.
#
# (2026-11-25, b49fix2 P2-62): the old 5e banned " async " and
# "(any " on the theory that SWIFT_VERSION = 5.0 forbids concurrency.
# The premise was false and the guard was dead: the app ships real
# Task/await (MusicPlayerView.swift:320-322, :1159-1166,
# MusicSearchViewModel.swift:590-591), neither of which contains
# " async ", and both Task commits (ff3cb512, f95d51f6) are ancestors
# of the build-48 release commit 42963ab, which shipped under
# SWIFT_VERSION = 5.0. The 5.0 pin does not forbid concurrency. 5e
# now DETECTS Task/await/async-let usage and reports the count
# (informational — allowed), instead of pretending to ban it.
_concurrency = len(re.findall(r"\bTask\s*[\[{<]|\bawait\s|\basync\s+let\b|\basync\s*\{", code_only))
check("5e. concurrency usage detected (Task/await/async let — allowed under Swift 5.0)",
      True, f"{_concurrency} uses in Swift sources")

# --- 6. all Swift files in the APP target's Sources phase -------------
# (2026-11-25, b49fix2 P2-64): the old check searched the whole
# PBXSourcesBuildPhase section (both the app's 162-file phase and the
# test target's 24-file phase) by bare file-name substring — a file
# present only in the test phase would have satisfied the app check.
# Scope it to the app target's phase id (...55); the test phase is
# checked separately by 6b. Fail if the phase id itself is not found,
# so a renumbered pbxproj fails loudly instead of passing vacuously.
_app_phase_m = re.search(
    r"000000000000000000000055 /\* Sources \*/ = \{isa = PBXSourcesBuildPhase;.*?files = \((.*?)\); runOnlyForDeploymentPostprocessing",
    pbx, re.S)
_app_phase = _app_phase_m.group(1) if _app_phase_m else ""
missing_phase = [f.name for f in swift_files if f"{f.name} in Sources" not in _app_phase]
check("6. all Swift files in app Sources phase (...55)",
      _app_phase_m is not None and not missing_phase,
      "app phase id ...55 not found" if _app_phase_m is None else str(missing_phase))

# --- 6b. test target membership + imports (Xcode HAoStudioTests) -------
# (2026-11-25, b49fix2 P2-65): preflight never looked at the test
# target — 9 files were unwired for months and one imported a
# nonexistent module (MusicFeatures). Every .swift under ios/Tests
# that imports the app module must be in the test Sources phase
# (...1C6), and no test file may import a module that does not exist
# (AppCore for the SwiftPM targets, HAoStudio for the Xcode target).
# Imports are read from comment-stripped text: several files mention
# "@testable import HAoStudio" in a header comment too.
_test_phase_m = re.search(
    r"0000000000000000000001C6 /\* Sources \*/ = \{isa = PBXSourcesBuildPhase;.*?files = \((.*?)\); runOnlyForDeploymentPostprocessing",
    pbx, re.S)
_test_phase = _test_phase_m.group(1) if _test_phase_m else ""
_test_files = sorted((REPO / "ios/Tests").rglob("*.swift"))


def _test_imports(path):
    code = re.sub(r"//.*", "", path.read_text())
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.DOTALL)
    return re.findall(r"@testable import (\w+)", code)


_unwired = [f.name for f in _test_files
            if "HAoStudio" in _test_imports(f)
            and f"{f.name} in Sources" not in _test_phase]
check("6b. HAoStudio-importing test files are in the test Sources phase (...1C6)",
      _test_phase_m is not None and not _unwired,
      "test phase id ...1C6 not found" if _test_phase_m is None else str(_unwired))
_bad_imports = []
for f in _test_files:
    for mod in _test_imports(f):
        if mod not in ("AppCore", "HAoStudio"):
            _bad_imports.append(f"{f.name}: {mod}")
check("6b-b. no test file imports a nonexistent module (AppCore/HAoStudio only)",
      not _bad_imports, str(_bad_imports))

# --- 7. codemagic.yaml ----------------------------------------------------
cm = (REPO / "codemagic.yaml").read_text()
try:
    import yaml
    y = yaml.safe_load(open(REPO / "codemagic.yaml"))
    check("7. codemagic.yaml parses", True,
          f"workflows: {list(y['workflows'].keys())}")
except ImportError:
    # (2026-11-25, b49fix2 P2-63): the old code PASSED when pyyaml was
    # missing, so an invalid codemagic.yaml passed on any machine
    # without the parser. Fail, not pass, when the parser is absent.
    check("7. codemagic.yaml parses (pyyaml missing — cannot verify)", False,
          "install pyyaml to verify the YAML")
except Exception as e:
    # A YAML parse error used to crash preflight with a traceback
    # instead of a clean FAIL (safe_load raises yaml.YAMLError, which
    # the old code never caught). Report it as check 7 failing.
    check("7. codemagic.yaml parses", False, f"yaml error: {e}")
check("7b. libmpv download step kept",
      "libmpv-darwin-build" in cm and "d428641cc6c100de8234eae04e229966e46949eb73fcabd526a008a02e9bf968" in cm)
check("7c. NO web-sync step", "cp -R web" not in cm and "ios/HAoStudio/web" not in cm
      and "Sync local web" not in cm)
check("7d. NO metadata-key inject step", _N_META_KEY not in cm and _N_META_CFG not in cm)
check("7e. pod install step kept (guarded)", "pod install" in cm)
check("7f. build uses project when no workspace",
      "HAoStudio.xcodeproj" in cm and "HAoStudio.xcworkspace" in cm)

# --- 8. build settings carried over ---------------------------------------
for needle, label in [
    ("PRODUCT_BUNDLE_IDENTIFIER = com.haostudio.standalone", "bundle id"),
    ("IPHONEOS_DEPLOYMENT_TARGET = 17.0", "deployment target 17.0"),
    ("SWIFT_VERSION = 5.0", "Swift 5.0"),
    ('TARGETED_DEVICE_FAMILY = "1,2"', "device family 1,2"),
    ("CODE_SIGN_ENTITLEMENTS = HAoStudio/HAoStudio.entitlements", "entitlements"),
    ("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon", "app icon name"),
    ('"$(PROJECT_DIR)/Vendor/libmpv"', "libmpv framework search path"),
    ('"@executable_path/Frameworks"', "runpath"),
    ("INFOPLIST_FILE = HAoStudio/Info.plist", "Info.plist path"),
]:
    check(f"8. build setting: {label}", needle in pbx)
check("8b. no second bundle id (Lyrics target gone)",
      "com.haostudio.standalone.lyrics" not in pbx)

# --- 9. splash spec values -------------------------------------------------
splash = (APP_DIR / "Splash/SplashView.swift").read_text()
for needle, label in [
    ("duration: 1.0", "logo 1.0s"), ("delay(0.15)", "shadow delay 0.15"),
    ("duration: 0.85", "shadow 0.85s"), ("duration: 0.3", "dot 0.3s / fade 0.3s"),
    ("delay(0.7)", "dot delay 0.7"), ("duration: 0.6", "breath 0.6s"),
    ("delay(0.9)", "breath delay 0.9"), ("now() + 1.5", "finish at 1.5s"),
    ("duration: 0.25", "waiting fade 0.25s"), ("0.069", "dot d = 0.069W"),
    ("0.678", "dot centre 0.678W"), ("0.409", "dot centre 0.409H"),
    ("0.22", "glow g = 0.22W"), ("0.55", "glow alpha 0.55"),
    ("1.12", "breath scale 1.12"), ("0.97", "logo start scale 0.97"),
    ("22", "logo float 22pt"), ("180", "logo 180"),
    ("0.96, green: 0.20, blue: 0.20", "dot red RGB(0.96, 0.20, 0.20)"),
    ("0.85", "glow maxAlpha 0.85"),
]:
    check(f"9. splash spec: {label}", needle in splash)

# --- 10. theme system -------------------------------------------------------
pals = re.findall(r"case \(\.(\w+), \.(light|dark)\):", theme_src)
check("10. 4 themes x light/dark = 8 palettes", len(pals) == 8, f"{len(pals)}: {sorted(set(pals))}")
check("10b. glassEffect with iOS 26 @available fallback",
      ".glassEffect" in (APP_DIR / "App/Glass.swift").read_text()
      and "#available(iOS 26.0, *)" in (APP_DIR / "App/Glass.swift").read_text()
      and ".ultraThinMaterial" in (APP_DIR / "App/Glass.swift").read_text())
# --- 10c. backgroundEffect never takes UIGlassEffect ----------------------
# (2026-11-23: Codemagic build #12 failed — UITabBarAppearance.
# backgroundEffect is UIBlurEffect, UIGlassEffect does not compile there.
# iOS 26's system tab bar is glass from its default background.)
check("10c. no UIGlassEffect assigned to backgroundEffect",
      "backgroundEffect = UIGlassEffect()" not in (APP_DIR / "App/GlassTabBar.swift").read_text())

# --- 11. LX scripts: no cleartext http:// API URL (ATS) ------------------
# (2026-11-25, b49fix2 P1-9): Info.plist forbids cleartext loads and
# LXEngine issues script requests via URLSession.shared, so every
# http:// API leg is dead on device — 8 of 13 scripts had one. This
# grep keeps a cleartext leg from shipping again. Benign http://
# occurrences are allowlisted by shape, not by file:
#   * `startsWith('http://')` validators (incl. the obfuscated
#     _u('cook5**') form at huibi.js:294) — they ACCEPT a URL, they
#     do not fetch one;
#   * `//` comments and `@see` doc links (xinghai.js:7);
#   * Referer header values (jiexiang.js:808) — a header, not a
#     request URL.
# Obfuscated _u('...') strings are decoded first (JS-unescape, then
# +5 per char — the scripts' own _u), so an obfuscated http:// base
# is caught exactly like a literal one.
_SCRIPTS = sorted((APP_DIR / "Services/LXEngine/Scripts").glob("*.js"))


def _u_decode(stored):
    val = re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t", "r": "\r"}.get(m.group(1), m.group(1)), stored)
    return "".join(chr(ord(c) + 5) for c in val)


def _ats_hits(path):
    hits = []
    for i, ln in enumerate(path.read_text().splitlines(), 1):
        for m in re.finditer(r"_u\('((?:[^'\\]|\\.)*)'\)", ln):
            if "http://" in _u_decode(m.group(1)) and "startsWith(" not in ln:
                hits.append(f"{path.name}:{i}: obfuscated http:// URL (decoded _u)")
        if "http://" in ln:
            stripped = ln.strip()
            if stripped.startswith(("*", "//")):
                continue
            if "@see" in ln or "Referer:" in ln or "startsWith(" in ln:
                continue
            hits.append(f"{path.name}:{i}: {stripped[:100]}")
    return hits


_ats = [h for p in _SCRIPTS for h in _ats_hits(p)]
check("11. LX scripts: no http:// API URL (ATS — literals + decoded _u)",
      not _ats, str(_ats[:5]) if _ats else f"{len(_SCRIPTS)} scripts clean")

# --- 11b. Swift side: no cleartext http:// request URL literal (ATS) ---
# (2026-11-25, b49fix6 P1-8/P2-52): the Kugou hot-playlist leg shipped a
# literal "http://mobilecdn.kugou.com/..." request URL that ATS blocks on
# device (NSAllowsArbitraryLoads=false) — check 11 only scans the LX
# scripts, so it sailed through preflight. This scans every Swift
# string literal in the shipped app code (ios/HAoStudio) and fails on
# anything that is not an allowlisted shape:
#   * `hasPrefix("http://")` validators — they TEST a URL, they do not
#     fetch one (DouyinSite, EmbyClient, MusicHTTP);
#   * http→https upgraders (`"https://" + url.dropFirst("http://"...`)
#     — they REMOVE cleartext, they do not fetch it (MusicHTTP,
#     CmsClient);
#   * `//` comments and the "要以 http:// 或 https:// 开头" validation
#     message — the scheme is mentioned, not fetched (VodDanmakuClient).
# A bare "http://" literal outside a validator/upgrader line also
# fails, so a future `"http://" + host` construction is caught too.
# Tests are excluded on purpose: fixtures use example.invalid,
# emby.local and 192.168.x by design, and they do not ship.
# Raw #"..."# and multiline """...""" blocks are yielded and judged
# line by line (a line starting with http:// fails); a literal
# "http" concatenated with "://..." is caught too (b49fix5 P2-20:
# the old scanner skipped both block forms whole, so a cleartext
# URL written in either form sailed through). The MIT licence text
# and the LX JS prelude contain no http://, so yielding them
# changes nothing for the current tree.
def _swift_string_literals(text):
    """Yield (contents, line) for every double-quoted string literal
    in Swift source, skipping // comments. Raw hash strings and
    triple-quoted blocks are yielded too (their contents are judged
    line by line by the caller) — skipping them whole used to let a
    cleartext URL written in either form sail through (b49fix5
    P2-20)."""
    lits = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if c == "#" and i + 1 < n and text[i + 1] == '"':
            if text.startswith('"""', i + 1):
                j = text.find('"""#', i + 4)
                if j >= 0:
                    lits.append((text[i + 4:j], text.count("\n", 0, i) + 1))
                i = n if j < 0 else j + 4
            else:
                j = i + 2
                while j < n and not (text[j] == '"' and j + 1 < n and text[j + 1] == "#"):
                    j += 1
                if j < n:
                    lits.append((text[i + 2:j], text.count("\n", 0, i) + 1))
                i = n if j >= n else j + 2
            continue
        if c == '"':
            if text.startswith('"""', i):
                j = text.find('"""', i + 3)
                if j >= 0:
                    lits.append((text[i + 3:j], text.count("\n", 0, i) + 1))
                i = n if j < 0 else j + 3
                continue
            j = i + 1
            buf = []
            while j < n:
                if text[j] == "\\" and j + 1 < n:
                    buf.append(text[j + 1])
                    j += 2
                    continue
                if text[j] == '"' or text[j] == "\n":
                    break
                buf.append(text[j])
                j += 1
            if j < n and text[j] == '"':
                lits.append(("".join(buf), text.count("\n", 0, i) + 1))
            i = j + 1 if j < n else n
            continue
        i += 1
    return lits


_swift_files = sorted(APP_DIR.rglob("*.swift"))
_swift_ats = []
for _p in _swift_files:
    _text = _p.read_text()
    _lines = _text.splitlines()
    for _lit, _ln in _swift_string_literals(_text):
        # Multiline contents are judged line by line: a line that
        # starts with http:// is a request URL whatever form the
        # literal was written in. (Single-line literals are the
        # one-line case of the same rule.)
        if re.search(r"(?m)^\s*http://\S", _lit):
            _swift_ats.append(f"{_p.relative_to(APP_DIR)}:{_ln}: cleartext http:// URL literal")
        elif _lit == "http://":
            _line = _lines[_ln - 1] if _ln - 1 < len(_lines) else ""
            if "hasPrefix" not in _line and "dropFirst" not in _line:
                _swift_ats.append(f"{_p.relative_to(APP_DIR)}:{_ln}: bare http:// literal outside validator/upgrader")
        elif _lit == "http":
            # "http" + "://host" builds the same cleartext URL by
            # concatenation; the scheme comparison `scheme == "http"`
            # has no `+ "://` on its line and is not flagged.
            _line = _lines[_ln - 1] if _ln - 1 < len(_lines) else ""
            if re.search(r'"http"\s*\+\s*"://', _line):
                _swift_ats.append(f"{_p.relative_to(APP_DIR)}:{_ln}: http:// URL built by concatenation")
check("11b. Swift side: no cleartext http:// request URL (ATS — literals only)",
      not _swift_ats, str(_swift_ats[:5]) if _swift_ats else f"{len(_swift_files)} Swift files clean")

print()
if failures:
    print(f"FAILED: {len(failures)} check(s): {failures}")
    sys.exit(1)
print("ALL PREFLIGHT CHECKS PASSED")
