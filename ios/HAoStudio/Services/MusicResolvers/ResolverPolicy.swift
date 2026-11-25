// ResolverPolicy.swift
// Resolver policy, pure and unit-testable (no JS, no network):
// speed ranking + cooldown, play-URL cache, pass budgets.
//
// Flutter parity (`music_resolvers.dart`):
// - Success updates an EMA latency (70% old / 30% new) and resets
//   the failure streak; an error bumps the streak and cools the job
//   after 3 consecutive failures (5 min); a TIMEOUT only feeds the
//   latency EMA (b49sweep P2-10: slow ≠ dead — the old "cool
//   immediately for 2 min" demoted a source on one slow response,
//   against the "hard errors only, never timeouts" rule); an EMPTY
//   answer records nothing at all (a source that is fast but has
//   no stock at this tier must not be cooled out of the tiers it
//   does serve).
// - Speeds persist under the S1 mapping key `hao_resolver_speed`
//   (`Documents/hao_resolver_speed.json`); persistence is
//   best-effort and throttled (every 10 attempts or 5 s).
// - Play-URL cache: 1 h TTL, 200-entry cap, key
//   `songId|platform|quality`. The 1 h TTL is uniform: no source
//   publishes a real expiry, so per-source TTLs would be invented
//   numbers — instead an URL that fails at playback is evicted
//   explicitly (`evictPlayUrl`), and the cache is in-memory only
//   (the `hao_play_url_cache:` family is NOT migrated, per S1).
// - Budgets (P0-16 rework): a whole resolve is capped at 8 s; the
//   FIRST tier pass is capped at 5 s and 3 s are reserved for the
//   lower tiers (each later pass at most 2 s); a single job is
//   capped at 3 s. The first tier can never eat the whole budget.

import Foundation

// MARK: - Budgets (P0-16)

enum ResolverBudget {
    /// Whole-resolve deadline.
    static let total: TimeInterval = 8
    /// First tier pass cap — 3 s stay reserved for lower tiers.
    static let firstPassCap: TimeInterval = 5
    /// Later tier pass cap.
    static let laterPassCap: TimeInterval = 2
    /// Single job cap.
    static let perJob: TimeInterval = 3

    /// Pass budget for pass `index` (0 = first tier), bounded by
    /// the time remaining in the whole resolve.
    static func passBudget(passIndex: Int, remaining: TimeInterval) -> TimeInterval {
        let cap = passIndex == 0 ? firstPassCap : laterPassCap
        return min(cap, remaining)
    }
}

// MARK: - Speed ranking + cooldown

/// One job's persisted speed record (`hao_resolver_speed.json`).
struct ResolverSpeedRecord: Codable {
    var avg: Int?
    var fails: Int?
    var cooledUntilMs: Int?

    enum CodingKeys: String, CodingKey {
        case avg
        case fails
        case cooled
    }

    init(avg: Int? = nil, fails: Int? = nil, cooledUntilMs: Int? = nil) {
        self.avg = avg
        self.fails = fails
        self.cooledUntilMs = cooledUntilMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        avg = try container.decodeIfPresent(Int.self, forKey: .avg)
        fails = try container.decodeIfPresent(Int.self, forKey: .fails)
        cooledUntilMs = try container.decodeIfPresent(Int.self, forKey: .cooled)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(avg, forKey: .avg)
        try container.encodeIfPresent(fails, forKey: .fails)
        try container.encodeIfPresent(cooledUntilMs, forKey: .cooled)
    }
}

/// Speed ranking + cooldown for resolver jobs. Threading: the
/// resolver calls this only from its serial work queue; tests call
/// it directly. `now` is injectable for tests.
final class ResolverCooldown {
    static let speedKey = "hao_resolver_speed"
    /// Unknown speed sorts in the middle (Flutter: 500 ms).
    static let unknownSpeedMs = 500
    static let coolAfterFails = 3
    static let coolFor: TimeInterval = 5 * 60

    private(set) var averages: [String: Int] = [:]
    private(set) var fails: [String: Int] = [:]
    private(set) var cooledUntil: [String: Date] = [:]

    private let documentsDirectory: URL?
    private var attemptsSinceSave = 0
    private var lastSaveAt = Date()
    var now: () -> Date = { Date() }

    init(documentsDirectory: URL? = nil) {
        self.documentsDirectory = documentsDirectory
        load()
    }

    // MARK: - Recording

    enum Outcome {
        case success
        case empty
        case error
        case timeout
    }

    func record(_ key: String, outcome: Outcome, milliseconds: Int) {
        switch outcome {
        case .success:
            let prev = averages[key]
            averages[key] = prev == nil ? milliseconds : (prev! * 7 + milliseconds * 3) / 10
            fails.removeValue(forKey: key)
            cooledUntil.removeValue(forKey: key)
        case .empty:
            // A fast "no" is not a failure — nothing changes.
            return
        case .error:
            let count = (fails[key] ?? 0) + 1
            fails[key] = count
            if count >= Self.coolAfterFails {
                cooledUntil[key] = now().addingTimeInterval(Self.coolFor)
            }
        case .timeout:
            // b49sweep P2-10: a timeout is "slow", not "dead" —
            // it only feeds the latency EMA (the timeout duration
            // is a lower-bound latency sample), never the failure
            // streak and never a cooldown.
            let prev = averages[key]
            averages[key] = prev == nil ? milliseconds : (prev! * 7 + milliseconds * 3) / 10
        }
        attemptsSinceSave += 1
        if attemptsSinceSave >= 10 || now().timeIntervalSince(lastSaveAt) >= 5 {
            attemptsSinceSave = 0
            save()
        }
    }

    func isCoolingDown(_ key: String) -> Bool {
        guard let until = cooledUntil[key] else { return false }
        if now() < until { return true }
        cooledUntil.removeValue(forKey: key)
        return false
    }

    func averageMs(_ key: String) -> Int {
        averages[key] ?? Self.unknownSpeedMs
    }

    func saveNow() {
        save()
    }

    /// b49sweep P1-5: forget the cooldown + failure streak for a
    /// set of sources (manual play re-asks every source — a
    /// source cooled down by earlier hard errors is tried again
    /// immediately). Latency averages are kept: they are real
    /// speed data, not failure state. Persists immediately so a
    /// relaunch does not resurrect the cooldown.
    func clear(keys: [String]) {
        guard !keys.isEmpty else { return }
        for key in keys {
            cooledUntil.removeValue(forKey: key)
            fails.removeValue(forKey: key)
        }
        saveNow()
    }

    // MARK: - Persistence (best-effort)

    private func load() {
        guard let dir = documentsDirectory ?? LocalStore.documentsDirectoryOrNil() else { return }
        let url = dir.appendingPathComponent("\(Self.speedKey).json")
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: ResolverSpeedRecord].self, from: data)
        else { return }
        for (key, record) in map {
            if let avg = record.avg { averages[key] = avg }
            if let fails = record.fails { self.fails[key] = fails }
            if let ms = record.cooledUntilMs {
                cooledUntil[key] = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
            }
        }
    }

    private func save() {
        // b49fix18 D-7: the write takes
        // MigrationStore.collectionWriteQueue, the same queue
        // the backup import / rollback takes for
        // hao_resolver_speed — a speed save (every 10 resolves
        // or ≥ 5 s) landing inside the restore's remove → copy
        // gap no longer cancels the rollback. Resolution never
        // runs while holding that queue (the import writes the
        // file directly, it never calls back into the
        // resolver), so taking it here cannot deadlock.
        MigrationStore.collectionWriteQueue.sync {
            saveLocked()
        }
    }

    /// The speed write itself, assuming the caller's queue is
    /// held (b49fix18 D-7): save() takes
    /// collectionWriteQueue, so the body must not sync on it
    /// again.
    private func saveLocked() {
        guard let dir = documentsDirectory ?? LocalStore.documentsDirectoryOrNil() else { return }
        lastSaveAt = now()
        var map: [String: ResolverSpeedRecord] = [:]
        for key in Set(averages.keys).union(fails.keys).union(cooledUntil.keys) {
            map[key] = ResolverSpeedRecord(
                avg: averages[key],
                fails: fails[key],
                cooledUntilMs: cooledUntil[key].map { Int($0.timeIntervalSince1970 * 1000) })
        }
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(
            to: dir.appendingPathComponent("\(Self.speedKey).json"),
            options: [.atomic])
    }
}

// MARK: - Play-URL cache (1 h TTL, 200-entry cap, in-memory)

/// One cached play URL with the tier it was actually served at.
struct CachedPlayURL {
    let url: String
    let tier: AudioQuality
    let expiresAt: Date
}

final class PlayURLCache {
    static let ttl: TimeInterval = 60 * 60
    static let maxEntries = 200

    private var entries: [String: CachedPlayURL] = [:]
    /// Insertion order (oldest first) for the 200-entry cap.
    private var order: [String] = []
    var now: () -> Date = { Date() }

    static func key(songId: String, platform: String, quality: AudioQuality) -> String {
        "\(songId)|\(platform)|\(quality.lxCode)"
    }

    func get(_ key: String) -> CachedPlayURL? {
        guard let entry = entries[key] else { return nil }
        if now() >= entry.expiresAt {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        return entry
    }

    func put(_ key: String, url: String, tier: AudioQuality) {
        if entries[key] == nil {
            order.append(key)
            while order.count > Self.maxEntries, let oldest = order.first {
                order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
        entries[key] = CachedPlayURL(url: url, tier: tier, expiresAt: now().addingTimeInterval(Self.ttl))
    }

    /// Drop a cached URL (e.g. it failed at playback): the next
    /// resolve for this song re-asks the sources.
    func evict(_ key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    var count: Int { entries.count }
}

private extension LocalStore {
    /// Documents directory, nil when the app container is unavailable
    /// (unit tests without a host app). Never throws.
    static func documentsDirectoryOrNil() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}

// MARK: - b45-F: 10-minute failure memory (plan §7.4)
//
// When a track is skipped, the next resolve does NOT re-ask the
// sources that just failed for that song: a failure is remembered
// per source + song for 10 minutes (max 500 entries, expired
// entries purged). Nothing is deleted: a 403/444 is geo-blocking,
// not death — the source stays in the list and the memory only
// expires. A later success clears the entry. In-memory only;
// the resolver calls this from its serial work queue.

final class ResolveFailureMemory {
    static let ttl: TimeInterval = 10 * 60
    static let maxEntries = 500

    private var failedAt: [String: Date] = [:]
    var now: () -> Date = { Date() }

    static func key(sourceKey: String, songId: String) -> String {
        "\(sourceKey)|\(songId)"
    }

    func record(sourceKey: String, songId: String) {
        purgeExpired()
        failedAt[Self.key(sourceKey: sourceKey, songId: songId)] = now()
        while failedAt.count > Self.maxEntries, let oldest = failedAt.min(by: { $0.value < $1.value })?.key {
            failedAt.removeValue(forKey: oldest)
        }
    }

    /// b46: forget every failure recorded for one song (manual
    /// play: the user asked for this song now, so all sources
    /// are re-asked). Keys are `sourceKey|songId`.
    func clear(songId: String) {
        purgeExpired()
        let suffix = "|\(songId)"
        for key in failedAt.keys where key.hasSuffix(suffix) {
            failedAt.removeValue(forKey: key)
        }
    }

    /// b49sweep P1-5: the source keys that failed for one song
    /// (manual play re-asks every source — the cooldown must be
    /// cleared for the same keys, not just the failure memory).
    /// The source key is the part before the `|songId` suffix.
    func sourceKeys(forSongId songId: String) -> [String] {
        purgeExpired()
        let suffix = "|\(songId)"
        return failedAt.keys
            .filter { $0.hasSuffix(suffix) }
            .map { String($0.dropLast(suffix.count)) }
    }

    /// True when this source failed for this song within the TTL.
    /// `before` bounds the memory to failures recorded before a
    /// resolve started: a source that fails mid-resolve must still
    /// be tried at the lower tiers of the same resolve.
    func isFailed(sourceKey: String, songId: String, before: Date? = nil) -> Bool {
        guard let at = failedAt[Self.key(sourceKey: sourceKey, songId: songId)] else { return false }
        if now().timeIntervalSince(at) >= Self.ttl {
            failedAt.removeValue(forKey: Self.key(sourceKey: sourceKey, songId: songId))
            return false
        }
        if let before = before { return at < before }
        return true
    }

    func clear(sourceKey: String, songId: String) {
        failedAt.removeValue(forKey: Self.key(sourceKey: sourceKey, songId: songId))
    }

    func purgeExpired() {
        let cutoff = now().addingTimeInterval(-Self.ttl)
        failedAt = failedAt.filter { $0.value > cutoff }
    }

    var count: Int { failedAt.count }
}

// MARK: - b45-F: cross-platform track matching (plan §7.3)
//
// "宁可不播，不播错版": a candidate from another platform only
// counts when it passes hard gates (duration, normalised title,
// version-tag set, first artist) and wins on score. Pure
// Foundation — the harness test drives this directly.

struct MatchCandidate {
    let title: String
    let artists: [String]
    let album: String?
    /// Full length in milliseconds, nil when unknown.
    let durationMs: Int?
}

enum AudioSourceTrackMatcher {
    /// Version tags: a conflict on either side vetoes the match.
    /// Both sides' tag sets must be identical.
    static let versionTags = [
        "live", "remix", "伴奏", "dj", "cover", "翻唱",
        "instrumental", "karaoke", "现场", "纯音乐",
    ]

    /// Hard-gate window for the duration check.
    static let maxDurationDifferenceMs = 5_000
    /// Only the first 5 candidates are ever considered.
    static let maxCandidates = 5

    /// Query string for a cross-platform lookup: title + first
    /// artist (+ NetEase id when the source is NetEase).
    static func queryString(title: String, artist: String, neteaseId: String? = nil) -> String {
        var parts = [title, artist].filter { !$0.isEmpty }
        if let id = neteaseId, !id.isEmpty { parts.append(id) }
        return parts.joined(separator: " ")
    }

    /// Version tags present in a title (lowercased contains).
    static func versionTagSet(of title: String) -> Set<String> {
        let lowered = title.lowercased()
        return Set(versionTags.filter { lowered.contains($0) })
    }

    /// Score a candidate against the expected track, or nil when
    /// a hard gate fails. Scoring: 100 − durationDiff/100,
    /// exact title +20, same album +15, identical artist set +10.
    static func matchScore(
        expectedTitle: String,
        expectedArtists: [String],
        expectedAlbum: String?,
        expectedDurationMs: Int?,
        candidate: MatchCandidate
    ) -> Int? {
        // Hard gate 1: duration within 5 s (unknown on either side
        // passes — it cannot prove a mismatch, and the other gates
        // still apply).
        var durationDiffMs = 0
        if let expected = expectedDurationMs, let got = candidate.durationMs {
            durationDiffMs = abs(expected - got)
            guard durationDiffMs <= maxDurationDifferenceMs else { return nil }
        }
        // Hard gate 2: normalised title equal, or equal after
        // stripping brackets / subtitles.
        let expectedNorm = MusicText.normalizeName(expectedTitle)
        let candidateNorm = MusicText.normalizeName(candidate.title)
        let expectedBase = MusicText.normalizeName(MusicText.baseSongTitle(expectedTitle))
        let candidateBase = MusicText.normalizeName(MusicText.baseSongTitle(candidate.title))
        let titleMatches = expectedNorm == candidateNorm
            || (!expectedBase.isEmpty && expectedBase == candidateBase)
        guard titleMatches else { return nil }
        // Hard gate 3: version-tag sets must be identical — a
        // live / remix / 伴奏 / cover on one side only vetoes.
        guard versionTagSet(of: expectedTitle) == versionTagSet(of: candidate.title) else { return nil }
        // Hard gate 4: the first artist must appear among the
        // candidate's artists (normalised; empty expected list
        // passes — nothing to check against).
        let expectedFirst = expectedArtists.first.map { MusicText.normalizeName($0) } ?? ""
        if !expectedFirst.isEmpty {
            let candidateArtists = candidate.artists.map { MusicText.normalizeName($0) }
            guard candidateArtists.contains(expectedFirst) else { return nil }
        }
        // Score.
        var score = 100 - durationDiffMs / 100
        if expectedNorm == candidateNorm { score += 20 }
        if let expectedAlbum = expectedAlbum, !expectedAlbum.isEmpty,
           let candidateAlbum = candidate.album,
           MusicText.normalizeName(expectedAlbum) == MusicText.normalizeName(candidateAlbum) {
            score += 15
        }
        let expectedSet = Set(expectedArtists.map { MusicText.normalizeName($0) }.filter { !$0.isEmpty })
        let candidateSet = Set(candidate.artists.map { MusicText.normalizeName($0) }.filter { !$0.isEmpty })
        if !expectedSet.isEmpty && expectedSet == candidateSet { score += 10 }
        return score
    }

    /// Best match among the first 5 candidates, or nil when none
    /// passes the gates. Returns the candidate index + score.
    static func bestMatch(
        expectedTitle: String,
        expectedArtists: [String],
        expectedAlbum: String?,
        expectedDurationMs: Int?,
        candidates: [MatchCandidate]
    ) -> (index: Int, score: Int)? {
        var best: (index: Int, score: Int)?
        for (index, candidate) in candidates.prefix(maxCandidates).enumerated() {
            guard let score = matchScore(
                expectedTitle: expectedTitle, expectedArtists: expectedArtists,
                expectedAlbum: expectedAlbum, expectedDurationMs: expectedDurationMs,
                candidate: candidate) else { continue }
            if best == nil || score > best!.score { best = (index, score) }
        }
        return best
    }
}

// MARK: - b45-F: 10-minute match cache (plan §7.3/§7.4)
//
// Cross-platform match answers are cached for 10 minutes
// (max 300). Only definite answers are stored — errors are
// never cached (there is no error API at all by construction).

final class TrackMatchCache {
    static let ttl: TimeInterval = 10 * 60
    static let maxEntries = 300

    struct Entry {
        let matchedKey: String
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    var now: () -> Date = { Date() }

    func get(_ key: String) -> String? {
        guard let entry = entries[key] else { return nil }
        if now() >= entry.expiresAt {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        return entry.matchedKey
    }

    func put(_ key: String, matchedKey: String) {
        if entries[key] == nil {
            order.append(key)
            while order.count > Self.maxEntries, let oldest = order.first {
                order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
        entries[key] = Entry(matchedKey: matchedKey, expiresAt: now().addingTimeInterval(Self.ttl))
    }

    var count: Int { entries.count }
}
