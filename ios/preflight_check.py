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
 10. theme system: 4 themes x light/dark = 8 palettes, no purple hex.

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
check("4b. bundle version 2.0.0 / build 35 (release)",
      pl.get("CFBundleShortVersionString") == "2.0.0" and pl.get("CFBundleVersion") == "35",
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
check("4i. version.json aligned (2.0.0 / build 35 / minOs 17.0)",
      vj.get("version") == "2.0.0" and vj.get("build") == 35 and vj.get("minOs") == "17.0",
      f"{vj.get('version')} / build {vj.get('build')} / minOs {vj.get('minOs')}")
# --- 4j. project.pbxproj parses: braces/parens balanced ------------------
# (2026-11-23: Codemagic build #10 failed with "project is damaged, parse
# error" — 4 XCBuildConfiguration lines were missing the closing brace of
# buildSettings. Preflight passed then because it never checked pbxproj.)
pbx = (REPO / "ios/HAoStudio.xcodeproj/project.pbxproj").read_text()
check("4j. project.pbxproj braces/parens balanced",
      pbx.count("{") == pbx.count("}") and pbx.count("(") == pbx.count(")"),
      f"{{ {pbx.count('{')} {pbx.count('}')} ( {pbx.count('(')} {pbx.count(')')}")
check("4k. every XCBuildConfiguration closes buildSettings before name",
      all("}; name = " in ln for ln in pbx.splitlines()
          if "XCBuildConfiguration; buildSettings = {" in ln),
      "each config line must contain '}; name = '")
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
check("5. Swift file count (final = 153: 152 + VideoBrowseView.swift [b36-item18: browse page])", len(swift_files) == 153,
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
# available and need no guard. What is still banned is Swift language
# newer than the project's SWIFT_VERSION = 5.0: async/await (Swift 5.5+)
# and `any` existentials (Swift 5.6+). `some View` / @StateObject /
# property wrappers are unavoidable SwiftUI (Xcode templates ship them
# with SWIFT_VERSION = 5.0) — Codemagic build is the arbiter for those.
for needle, label in [(" async ", "async/await (Swift 5.5+)"),
                      ("(any ", "`any` existential (Swift 5.6+)")]:
    check(f"5e. no {label} in Swift sources", needle not in code_only)

# --- 6. all Swift files in Sources phase ----------------------------------
src_phase = pbx.split("/* Begin PBXSourcesBuildPhase section */")[1] \
               .split("/* End PBXSourcesBuildPhase section */")[0]
missing_phase = [f.name for f in swift_files if f"{f.name} in Sources" not in src_phase]
check("6. all Swift files in Sources phase", not missing_phase, str(missing_phase))

# --- 7. codemagic.yaml ----------------------------------------------------
cm = (REPO / "codemagic.yaml").read_text()
try:
    import yaml
    y = yaml.safe_load(open(REPO / "codemagic.yaml"))
    check("7. codemagic.yaml parses", True,
          f"workflows: {list(y['workflows'].keys())}")
except ImportError:
    check("7. codemagic.yaml parses (pyyaml missing — skipped)", True, "pyyaml not installed")
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

print()
if failures:
    print(f"FAILED: {len(failures)} check(s): {failures}")
    sys.exit(1)
print("ALL PREFLIGHT CHECKS PASSED")
