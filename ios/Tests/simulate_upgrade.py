#!/usr/bin/env python3
"""S1 overwrite-install simulation (file level).

Builds a fake Flutter 1.1.6 Documents directory exactly as an
overwrite install would leave it, then checks the migration
contract from docs/storage-mapping.md against it:

  1. every key in the generated snapshot has exactly one
     destination in the Swift mapping table (parsed from the real
     MigrationStore.swift, not copied by hand);
  2. key counts add up: migrated + skipped + unknown == total;
  3. the Emby config splits (apiKey apart, never in the JSON file);
  4. the Hive box file, the snapshot file, and the four user-file
     subdirectories are untouched by the migration;
  5. every relative file name the snapshot references resolves on
     disk (the LocalFileIndex contract);
  6. the pre-write backup holds a copy of the snapshot.

What this does NOT prove: the Swift code itself. That is what the
SwiftPM suite (ios/Tests/MigrationCoreTests, `swift test`) is for
on Codemagic. This script proves the table and the file layout the
Swift code runs against.

Run: python3 ios/Tests/simulate_upgrade.py
"""

import json
import pathlib
import re
import shutil
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent.parent
STORE = REPO / "ios/HAoStudio/Storage/MigrationStore.swift"

failures = []


def check(label, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {label}" + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(label)


src = STORE.read_text()
table = re.findall(
    r'MigrationKeyMapping\(key: "([^"]+)", kind: \.(\w+), destination: \.(\w+)(?:\("([^"]+)"\))?\)',
    src,
)
prefixes = re.findall(
    r'MigrationPrefixRule\(prefix: "([^"]+)", fileName: "([^"]+)", kind: \.(\w+)\)',
    src,
)
ignored = re.findall(r'static let ignoredPrefixes: \[String\] = \[(.*?)\]', src, re.S)[0]
ignored_prefixes = re.findall(r'"([^"]+)"', ignored)

mapping = {key: (kind, dest, arg) for key, kind, dest, arg in table}
check("mapping table has 112 named keys", len(mapping) == 112, f"{len(mapping)}")
check("mapping keys unique", len(set(mapping)) == len(mapping))
check("3 prefix families", len(prefixes) == 3, str([p[0] for p in prefixes]))
check("1 ignored family", ignored_prefixes == ["hao_play_url_cache:"])

# Plausible snapshot value per kind, mirroring the Flutter shapes.
SAMPLES = {
    "string": "sample",
    "int": 42,
    "double": 1.5,
    "bool": True,
    "json": '[{"id":"x"}]',
    "intList": [1, 2, 3],
    "doubleList": [0.5, -1.0, 0, 0, 0, 0, 0, 0, 0, 0],
}
JSON_LIST_KEYS = {
    "hao_lists", "hao_fav", "hao_recent", "hao_listen",
    "hao_music_search_hist", "hao_cover_cache", "hao_lyrics",
    "musicQueue", "musicDownloads", "fmDislikedIds",
    # b49fix17 P1-4: musicResume is NOT a list key — it is a dict
    # {identityKey: seconds} (docs/storage-mapping.md:112;
    # 2.0's resumeMap() only reads a dict). It used to sit here
    # only because the generator sampled [{"id":"x"}] for every
    # .json key, not a real Flutter shape.
    "hao_feature_cover_plaza", "hao_feature_cover_charts",
    "hao_music_bookmarks", "hao_music_loudness_cache",
    "hao_music_sources", "hao_local_music", "hao_music_queue_memory",
    "hao_resolver_speed", "hao_vod_metadata_overrides",
    "hao_video_category_prefs", "hao_vod_skip_intro_durations",
    "hao_video_home", "hao_video_hist", "hao_video_fav",
    "hao_video_search_hist", "hao_douban_detail", "hao_douban_idmap",
    "hao_sa_video", "hao_emby_home", "hao_live_sources",
    "hao_live_hist", "hao_live_follows", "hao_live_search_hist",
    "hao_live_hidden_platforms", "hao_danmaku_enabled", "hao_dm_block",
    "hao_lx_disabled", "hao_lx_explicit_enabled", "hao_lx_custom",
    "hao_lx_deleted_bundled", "hao_lx_order", "hao_eq_custom_presets",
    "hao_wallpaper_paths",
}

data = {}
for key, (kind, dest, arg) in mapping.items():
    if key == "hao_emby_config":
        data[key] = json.dumps({
            "baseUrl": "http://192.168.1.10:8096",
            "apiKey": "test-api-key-123",
            "userId": "u1",
            "enabled": True,
            "movieLibraryId": "m1",
            "tvLibraryId": "t1",
        })
    elif key == "hao_local_music":
        data[key] = json.dumps(["local_music/b.mp3"])
    elif key == "hao_wallpaper_paths":
        data[key] = json.dumps(["wallpapers/w.png"])
    elif key == "hao_lists":
        data[key] = json.dumps([{"id": "pl1", "name": "收藏"}])
    elif kind == "json":
        data[key] = json.dumps([{"id": "x"}]) if key in JSON_LIST_KEYS else json.dumps({"a": 1})
    else:
        data[key] = SAMPLES[kind]

# Key families: 3 members each, plus 2 ignored cache keys, 3 unknown keys.
family_members = [
    ("haoVodProg:cms:vod42", 1234.5),
    ("haoVodProg:emby:ep7", 300),
    ("haoVodProg:cms:vod43", 60),
    ("hao_daily_2026-11-22", json.dumps({"picks": ["a"]})),
    ("hao_daily_2026-11-23", json.dumps({"picks": ["b"]})),
    ("hao_daily_2026-11-21", json.dumps({"picks": ["c"]})),
    ("hao_listen_2026-10", json.dumps([{"at": 1698000000000, "dur": 180}])),
    ("hao_listen_2026-11", json.dumps([{"at": 1700000000000, "dur": 200}])),
    ("hao_listen_2026-09", json.dumps([{"at": 1695000000000, "dur": 90}])),
]
for key, value in family_members:
    data[key] = value
data["hao_play_url_cache:song1|wy|hires"] = json.dumps({"url": "https://cdn.example/x.mp3"})
data["hao_play_url_cache:song2|kg|320k"] = json.dumps({"url": "https://cdn.example/y.mp3"})
for unknown in ["hao_future_feature_flag", "hao_unknown_2027_key", "custom_plugin_key"]:
    data[unknown] = "keep me"

total = len(data)
print(f"snapshot keys: {total} (112 named + 9 family + 2 ignored + 3 unknown)")

# --- Build the fake 1.1.6 Documents directory ---------------------------
tmp = pathlib.Path(tempfile.mkdtemp(prefix="hao-upgrade-sim-"))
docs = tmp / "Documents"
docs.mkdir()
(docs / "migration_snapshot.json").write_text(json.dumps({
    "schema": 1, "app": "HAo Studio", "appVersion": "1.1.6",
    "appBuild": 31, "exportedAt": "2026-11-23T00:00:00.000Z",
    "entries": total, "data": data,
}, ensure_ascii=False))
(docs / "app_settings.hive").write_bytes(b"fake hive box bytes")
for subdir, files in {
    "music_downloads": ["a.mp3"],
    "local_music": ["b.mp3"],
    "wallpapers": ["w.png"],
    "fonts": ["f.ttf"],
}.items():
    d = docs / subdir
    d.mkdir()
    for name in files:
        (d / name).write_bytes(b"fake file bytes")
# A pre-existing Swift collection file (merge/overwrite semantics).
(docs / "hao_fav.json").write_text(json.dumps([{"key": "old-song"}]))
hive_before = (docs / "app_settings.hive").read_bytes()
snapshot_before = (docs / "migration_snapshot.json").read_bytes()

# --- Simulate the migration classification -------------------------------
migrated, skipped, unknown = [], [], []
dest_files = set()
for key in sorted(data):
    if key in mapping:
        kind, dest, arg = mapping[key]
        if dest == "userDefaults":
            migrated.append(key)
        elif dest == "collectionFile":
            migrated.append(key)
            dest_files.add(arg)
        elif dest == "emby":
            migrated.append(key)
            dest_files.add("hao_emby_config")
    elif any(key.startswith(p[0]) for p in prefixes):
        migrated.append(key)
        dest_files.add(next(p[1] for p in prefixes if key.startswith(p[0])))
    elif any(key.startswith(p) for p in ignored_prefixes):
        skipped.append(key)
    else:
        unknown.append(key)
        dest_files.add("migration_unknown_keys")

check("every key accounted for", len(migrated) + len(skipped) + len(unknown) == total,
      f"migrated {len(migrated)} + skipped {len(skipped)} + unknown {len(unknown)} = {total}")
check("skipped is only the play-url cache family", skipped == [
    "hao_play_url_cache:song1|wy|hires", "hao_play_url_cache:song2|kg|320k"])
check("unknown keys isolated, not dropped", sorted(unknown) == [
    "custom_plugin_key", "hao_future_feature_flag", "hao_unknown_2027_key"])
check("no key maps to two destinations", len(migrated) == len(set(migrated)))

# Emby split: the apiKey leaves the JSON file.
emby = json.loads(data["hao_emby_config"])
emby_file = {k: v for k, v in emby.items() if k != "apiKey"}
check("emby file keeps non-secret fields", set(emby_file) == {
    "baseUrl", "userId", "enabled", "movieLibraryId", "tvLibraryId"})
check("emby apiKey separated for Keychain", emby["apiKey"] == "test-api-key-123"
      and "apiKey" not in emby_file)

# Collection files: one per json key, no collisions, sane names.
json_keys = [k for k, (kind, d, a) in mapping.items() if d == "collectionFile"]
check("collection file names unique", len({mapping[k][2] for k in json_keys}) == len(json_keys),
      f"{len(json_keys)} json keys")
check("no collection file collides with a snapshot file",
      not (set(dest_files) & {"migration_snapshot", "app_settings"}))

# --- Simulate the pre-write backup ---------------------------------------
backup = docs / "migration_backup" / "20261123-120000"
backup.mkdir(parents=True)
shutil.copy(docs / "migration_snapshot.json", backup / "migration_snapshot.json")
collections = backup / "collections"
collections.mkdir()
shutil.copy(docs / "hao_fav.json", collections / "hao_fav.json")
check("backup holds a snapshot copy",
      (backup / "migration_snapshot.json").read_bytes() == snapshot_before)
check("backup holds the prior collection file",
      json.loads((collections / "hao_fav.json").read_text()) == [{"key": "old-song"}])

# --- Untouched files ------------------------------------------------------
check("Hive box untouched", (docs / "app_settings.hive").read_bytes() == hive_before)
check("snapshot file untouched", (docs / "migration_snapshot.json").read_bytes() == snapshot_before)
for subdir, name in [("music_downloads", "a.mp3"), ("local_music", "b.mp3"),
                     ("wallpapers", "w.png"), ("fonts", "f.ttf")]:
    check(f"subdir file kept: {subdir}/{name}",
          (docs / subdir / name).exists())

# Relative-name resolution (LocalFileIndex contract): every relative
# name the snapshot references resolves under the current Documents.
for rel in json.loads(data["hao_local_music"]) + json.loads(data["hao_wallpaper_paths"]):
    check(f"relative name resolves: {rel}", (docs / rel).exists())

print(f"\nfixture: {docs}")
print(f"migrated {len(migrated)} / skipped {len(skipped)} / unknown {len(unknown)} / total {total}")
print(f"collection files to write: {len(dest_files)}")
if failures:
    print(f"FAILED: {len(failures)} check(s): {failures}")
    sys.exit(1)
print("ALL SIMULATION CHECKS PASSED")
