// HAo Studio 2.0 — video models (S3 seam).
//
// Swift mirrors of the Flutter video models
// (standalone-app-merge23 lib/features/video/video_models.dart and
// lib/features/video/cms_sources.dart). Field names follow the
// Flutter originals so a reader can diff the two sides; behaviour
// differences are called out in comments. Leg B (services) fills
// these from CMS / Douban / Emby JSON; Leg C (UI) renders them;
// Leg A (player) consumes episodes + lines only.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

/// One CMS source. Shipped defaults live in CmsClient (Leg B);
/// the user list is persisted under the same Hive key name the
/// Flutter side uses (`hao_sa_video`) via MigrationStore's mapping,
/// so a migrated user keeps their sources.
struct VideoSource: Codable, Equatable, Identifiable {
    /// CMS source id (drifts on reseed — never hardcode video ids
    /// against it, never assume it survives a reseed).
    let id: Int
    let name: String
    let apiUrl: String
    /// "play" = trusted for playback, "search" = search only
    /// (play URLs not trusted — Flutter: 非凡 / 非凡主站).
    let kind: String
    let enabled: Bool
    /// Lower sorts first (Flutter: measured 2026-11-17, relative).
    let sort: Int

    var isPlaySource: Bool { kind == "play" }
}

/// One title in a list / search result. `id` is the CMS vod_id as
/// a string (ids drift on reseed; the stable identity for resume
/// is title + year, see VideoResumeKey). For an Emby item `id` is
/// the Emby item id instead, and `sourceId` is nil.
struct VideoItem: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let title: String
    let coverURL: URL?
    /// Release year as printed by the source ("2024"); nil when the
    /// source does not give one. Douban year-check (Leg B) uses it.
    let year: String?
    let typeName: String?
    let remarks: String?
    /// CMS source this item came from (nil for Emby items).
    let sourceId: Int?

    /// Which detail loader serves this item. CMS items always
    /// carry their source id (CmsClient.parseVideoItem); Emby
    /// items carry the Emby item id in `id` and no CMS source
    /// (EmbyClient.toVideoItem). A nil source id is therefore
    /// Emby — never a CMS item. The detail page resolves its
    /// loader from the item itself, so a history / favourite /
    /// search entry keeps its Emby identity instead of falling
    /// through to the CMS loader (which answers nil for it:
    /// fetchDetail guards on sourceId, so the page opened on an
    /// empty "暂无可播剧集" state — build 36 item 16).
    var detailSource: VideoDetailSource {
        sourceId == nil ? .emby : .cms
    }
}

/// Where a detail comes from: CMS detail (lines + Douban meta)
/// or Emby detail (streams as lines). Lives here (not the detail
/// view) so the routing decision is testable from AppCore.
enum VideoDetailSource: Equatable {
    case cms
    case emby
}

/// Pure detail-page routing decisions shared by the detail view
/// model and the unit tests (no I/O, no store reads).
enum VideoDetailRouting {

    /// Which line / episode a resume bookmark opens. Emby lines
    /// are seasons, so the resume episode may live in a later
    /// season, not the first line — searching only the first line
    /// used to reopen season 1 episode 1 instead of resuming.
    /// CMS lines are sources holding the same episodes, so the
    /// first line holding the episode at its recorded index wins
    /// there too. `lineName` is the recorded line (history entry):
    /// when it names a line, that line wins first — same-name
    /// episodes across seasons ("第 N 集" with no episode title)
    /// are otherwise indistinguishable. Nil when no line holds
    /// the resume episode.
    static func resumeSelection(
        lines: [PlayLine],
        resume: ResumeInfo,
        lineName: String? = nil
    ) -> (lineIndex: Int, episodeIndex: Int)? {
        // The recorded line first (exact season / source).
        if let lineName = lineName, !lineName.isEmpty,
           let lineIndex = lines.firstIndex(where: { $0.name == lineName }) {
            let line = lines[lineIndex]
            if line.episodes.indices.contains(resume.episodeIndex),
               line.episodes[resume.episodeIndex].name == resume.episodeName {
                return (lineIndex, resume.episodeIndex)
            }
            if let episodeIndex = line.episodes.firstIndex(where: { $0.name == resume.episodeName }) {
                return (lineIndex, episodeIndex)
            }
        }
        // Prefer the line where the resume episode sits at its
        // recorded index: same-name episodes across seasons (or
        // sources) are disambiguated by position.
        for (lineIndex, line) in lines.enumerated() {
            if line.episodes.indices.contains(resume.episodeIndex),
               line.episodes[resume.episodeIndex].name == resume.episodeName {
                return (lineIndex, resume.episodeIndex)
            }
        }
        for (lineIndex, line) in lines.enumerated() {
            if let episodeIndex = line.episodes.firstIndex(where: { $0.name == resume.episodeName }) {
                return (lineIndex, episodeIndex)
            }
        }
        return nil
    }
}

/// One playable episode inside a line.
struct PlayEpisode: Codable, Equatable, Identifiable {
    /// Episode name as printed ("第01集", "正片"). Empty from the
    /// source means "正片" (Flutter cms_client.dart).
    let name: String
    let url: URL?
    /// Position inside its line (0-based). Display numbering uses
    /// this, never the parsed number inside `name`.
    let index: Int
    /// Skip-intro/outro markers in seconds (Emby `Chapters`:
    /// IntroStart / IntroEnd / CreditsStart, from the IntroSkip
    /// plugin). Nil = the server returned no marker — never
    /// invent one. CMS episodes carry no markers at all (only the
    /// per-episode custom seconds in
    /// `VodSkipIntroDurations`). Optional with defaults, so
    /// stored / decoded episodes without these keys still decode.
    let introStart: Double?
    let introEnd: Double?
    let creditsStart: Double?

    var id: String { "\(index)-\(name)" }

    init(
        name: String,
        url: URL?,
        index: Int,
        introStart: Double? = nil,
        introEnd: Double? = nil,
        creditsStart: Double? = nil
    ) {
        self.name = name
        self.url = url
        self.index = index
        self.introStart = introStart
        self.introEnd = introEnd
        self.creditsStart = creditsStart
    }
}

/// One playback line （线路）: a named group of episodes from one
/// source path. The UI shows the line name; switching lines keeps
/// the episode index and resumes at the same position.
struct PlayLine: Codable, Equatable, Identifiable {
    let name: String
    let episodes: [PlayEpisode]

    var id: String { name }

    func episode(at index: Int) -> PlayEpisode? {
        guard episodes.indices.contains(index) else { return nil }
        return episodes[index]
    }
}

/// Metadata for a title. Douban is the SOLE metadata source (TMDB
/// removed — no TMDB calls, keys, or references anywhere).
struct VideoMeta: Codable, Equatable {
    let rating: Double?
    let year: String?
    let cast: [String]
    let synopsis: String?
    /// Douban subject id when known (used for the detail fetch).
    let doubanId: String?
}

/// Full detail for a title: the item, its play lines, and metadata.
/// `lines` is empty until the detail fetch resolves (CMS detail or
/// Emby streams); the detail view shows the cover + meta first and
/// fills the episode grid when lines arrive.
struct VideoDetail: Codable, Equatable {
    let item: VideoItem
    let lines: [PlayLine]
    let meta: VideoMeta?

    /// The line the player should open: first line with episodes.
    var firstPlayableLine: PlayLine? {
        lines.first { !$0.episodes.isEmpty }
    }
}

/// Stable resume identity. A CMS vod_id is NOT stable (ids drift on
/// reseed), so resume keys are title + year, exactly like the
/// Flutter side (ResumeInfo key). Two titles that share a title and
/// year collide on purpose — the Flutter side does the same.
enum VideoResumeKey {
    static func key(title: String, year: String?) -> String {
        let y = (year ?? "").trimmingCharacters(in: .whitespaces)
        return y.isEmpty ? title : "\(title)-\(y)"
    }

    /// PlaybackItem id for an episode: resume key + episode name.
    /// The coordinator, history and resume all use this one string.
    static func episodeId(title: String, year: String?, episodeName: String) -> String {
        "\(key(title: title, year: year))#\(episodeName)"
    }
}

/// One resume bookmark: where playback stopped, so the next open
/// continues at the same episode and position. Persisted by
/// VideoLibraryStore (Leg C) under the resume key.
struct ResumeInfo: Codable, Equatable {
    let key: String
    let episodeName: String
    let episodeIndex: Int
    let positionSeconds: Double
    let durationSeconds: Double
    let updatedAt: Date
}

/// One row on the video home tab (a category strip / recommendation
/// row). `items` are VideoItems; the row title is shown as-is.
struct VideoHomeRow: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let items: [VideoItem]
}
