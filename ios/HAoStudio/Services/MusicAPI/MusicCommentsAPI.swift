// MusicCommentsAPI.swift
// Comments, READ-ONLY. Posting / liking needs a platform login,
// which this app does not have — so there is no post/like API here,
// only fetch.
//
// Aggregation (Flutter `MusicApi.comments` parity): the song's own
// platform is fetched first; when a title is known, the same song
// is found on up to 3 other platforms (2.5 s cap) and their
// comments are merged. Hot comments are the top 15 by likes (with
// the top 5 liked ordinary comments promoted); the latest list is
// paged 30 at a time, newest first. Every upstream failing throws
// only when ALL of them failed — the UI leg surfaces that as an
// empty state, not a crash.
//
// Per-platform fetchers (8 s timeout, 30/page):
// - wy: `/api/v1/resource/comments/R_SO_4_<id>` (limit/offset)
// - tx: `fcg_global_comment_h5.fcg` (biztype 1, cmd 8)
// - kg: `comment/commentData` (hash/page/pagesize)
// - kw: `comment.kuwo.cn/com.s` (digest 0, sid/page/rows)

import Foundation

final class MusicCommentsAPI {
    static let shared = MusicCommentsAPI()

    static let pageSize = 30

    private let client: MusicAPIClient
    private let searchAPI: MusicSearchAPI

    init(client: MusicAPIClient = .shared, searchAPI: MusicSearchAPI = .shared) {
        self.client = client
        self.searchAPI = searchAPI
    }

    struct CommentsPage {
        let hot: [CommentItem]
        let latest: [CommentItem]
        let hasMore: Bool
    }

    /// Fetch comments for a song. `offset` pages the latest list
    /// (hot comments only come back when `offset == 0`).
    /// Completion fires once, on the main queue.
    func comments(
        songId: String,
        platform: MusicPlatform,
        title: String,
        artist: String,
        offset: Int,
        completion: @escaping (CommentsPage?) -> Void
    ) {
        let group = DispatchGroup()
        var firstResult: (hot: [CommentItem], list: [CommentItem])?
        group.enter()
        fetchFor(platform: platform, id: songId, offset: offset) { result in
            firstResult = result
            group.leave()
        }
        var altResults: [(hot: [CommentItem], list: [CommentItem])] = []
        if !title.isEmpty {
            group.enter()
            let others: [MusicPlatform] = [.wy, .tx, .kg, .kw].filter { $0 != platform }
            let altGroup = DispatchGroup()
            var found: [MusicTrack] = []
            let lock = NSLock()
            // The alt-platform search is capped at 2.5 s: on timeout
            // the legs are abandoned and the merge proceeds with
            // whatever was found (possibly nothing).
            var altDone = false
            func finishAltSearch() {
                guard !altDone else { return }
                altDone = true
                let targetTitle = MusicText.normalizeName(title)
                let targetArtist = MusicText.normalizeName(MusicAPIJSON.firstArtist(artist))
                var alts: [(platform: MusicPlatform, id: String)] = []
                lock.lock()
                let snapshot = found
                lock.unlock()
                for track in snapshot {
                    guard track.platform != platform else { continue }
                    guard MusicText.normalizeName(track.title) == targetTitle else { continue }
                    if !targetArtist.isEmpty,
                       MusicText.normalizeName(MusicAPIJSON.firstArtist(track.artist)) != targetArtist {
                        continue
                    }
                    alts.append((track.platform ?? platform, track.id))
                    if alts.count >= 3 { break }
                }
                if alts.isEmpty {
                    group.leave()
                    return
                }
                let fetchGroup = DispatchGroup()
                for alt in alts {
                    fetchGroup.enter()
                    self.fetchFor(platform: alt.platform, id: alt.id, offset: offset) { result in
                        if let result = result {
                            lock.lock()
                            altResults.append(result)
                            lock.unlock()
                        }
                        fetchGroup.leave()
                    }
                }
                fetchGroup.notify(queue: .main) { group.leave() }
            }
            for other in others {
                altGroup.enter()
                searchAPI.searchOne(platform: other, keyword: title) { tracks in
                    lock.lock()
                    found.append(contentsOf: tracks)
                    lock.unlock()
                    altGroup.leave()
                }
            }
            altGroup.notify(queue: .main) { finishAltSearch() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { finishAltSearch() }
        }
        group.notify(queue: .main) {
            var seen = Set<String>()
            var hot: [CommentItem] = []
            var pool: [CommentItem] = []
            var anyOk = false
            func key(_ c: CommentItem) -> String {
                "\(c.nick)|\(String(c.content.prefix(60)))"
            }
            let allResults = ([firstResult].compactMap { $0 }) + altResults
            for result in allResults {
                anyOk = true
                for c in result.hot where !c.content.isEmpty {
                    let k = key(c)
                    guard !seen.contains(k) else { continue }
                    seen.insert(k)
                    hot.append(c)
                }
                for c in result.list where !c.content.isEmpty {
                    let k = key(c)
                    guard !seen.contains(k) else { continue }
                    seen.insert(k)
                    pool.append(c)
                }
            }
            guard anyOk else {
                completion(nil)
                return
            }
            hot.sort { $0.likes > $1.likes }
            let extraTop = pool.filter { $0.likes > 0 }
                .sorted { $0.likes > $1.likes }
                .prefix(5)
            let hotKeys = Set(extraTop.map { key($0) })
            hot = (hot + extraTop).sorted { $0.likes > $1.likes }
            hot = Array(hot.prefix(15))
            let ordinary = pool.filter { !hotKeys.contains(key($0)) }
                .sorted { $0.time > $1.time }
            let latest = Array(ordinary.dropFirst(offset).prefix(Self.pageSize))
            completion(CommentsPage(
                hot: offset == 0 ? hot : [],
                latest: latest,
                hasMore: ordinary.count > offset + Self.pageSize))
        }
    }

    // MARK: - Per-platform fetchers

    private func fetchFor(
        platform: MusicPlatform,
        id: String,
        offset: Int,
        completion: @escaping ((hot: [CommentItem], list: [CommentItem])?) -> Void
    ) {
        switch platform {
        case .wy:
            commentsWy(id: id, limit: min(60 + offset, 100), offset: 0, completion: completion)
        case .tx:
            commentsTx(id: id, limit: min(40 + offset, 100), page: 0, completion: completion)
        case .kg:
            commentsKg(id: id, limit: min(40 + offset, 100), page: 1, completion: completion)
        case .kw:
            commentsKw(id: id, limit: min(40 + offset, 100), page: 1, completion: completion)
        case .mg:
            completion(nil)
        }
    }

    private func commentsWy(id: String, limit: Int, offset: Int, completion: @escaping ((hot: [CommentItem], list: [CommentItem])?) -> Void) {
        client.getJson(
            "https://music.163.com/api/v1/resource/comments/R_SO_4_\(id)?limit=\(limit)&offset=\(offset)",
            headers: ["User-Agent": MusicUA.value],
            timeout: 8
        ) { json in
            guard let json = json else { completion(nil); return }
            func map(_ c: [String: Any]) -> CommentItem {
                let user = MusicAPIJSON.asMap(c["user"]) ?? [:]
                // b49fix2 P2-21: nested replies — beReplied is the
                // comment this comment replied to (user + content).
                let replies = MusicAPIJSON.asList(c["beReplied"]).map { r in
                    let replyUser = MusicAPIJSON.asMap(r["user"]) ?? [:]
                    return CommentReply(
                        nick: MusicAPIJSON.asString(replyUser["nickname"]),
                        content: MusicAPIJSON.asString(r["content"]))
                }
                return CommentItem(
                    nick: MusicAPIJSON.asString(user["nickname"]),
                    avatar: MusicText.toHttps(MusicAPIJSON.asString(user["avatarUrl"])),
                    content: MusicAPIJSON.asString(c["content"]),
                    likes: MusicAPIJSON.asInt(c["likedCount"]),
                    time: MusicAPIJSON.asInt(c["time"]),
                    platform: .wy,
                    replies: replies)
            }
            completion((
                hot: MusicAPIJSON.asList(json["hotComments"]).map(map),
                list: MusicAPIJSON.asList(json["comments"]).map(map)))
        }
    }

    private func commentsTx(id: String, limit: Int, page: Int, completion: @escaping ((hot: [CommentItem], list: [CommentItem])?) -> Void) {
        client.getJson(
            "https://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg",
            query: [
                "biztype": "1", "topid": id, "cmd": "8",
                "needmusiccrit": "0", "pagenum": "\(page)", "pagesize": "\(limit)",
            ],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value],
            timeout: 8
        ) { json in
            guard let json = json else { completion(nil); return }
            let comment = MusicAPIJSON.asMap(json["comment"]) ?? [:]
            completion((
                hot: [],
                list: MusicAPIJSON.asList(comment["commentlist"]).map { c in
                    CommentItem(
                        nick: MusicAPIJSON.asString(c["nick"]),
                        avatar: MusicAPIJSON.asString(c["avatarurl"]),
                        content: MusicAPIJSON.asString(c["rootcommentcontent"]),
                        likes: MusicAPIJSON.asInt(c["praisenum"]),
                        time: MusicAPIJSON.asInt(c["time"]) * 1000,
                        platform: .tx)
                }))
        }
    }

    private func commentsKg(id: String, limit: Int, page: Int, completion: @escaping ((hot: [CommentItem], list: [CommentItem])?) -> Void) {
        client.getJson(
            "https://www.kugou.com/yy/index.php?r=comment/commentData&hash=\(id)&page=\(page)&pagesize=\(limit)",
            headers: ["User-Agent": MusicUA.value],
            timeout: 8
        ) { json in
            guard let json = json else { completion(nil); return }
            let data = MusicAPIJSON.asMap(json["data"]) ?? [:]
            var list = MusicAPIJSON.asList(data["comment_list"])
            if list.isEmpty { list = MusicAPIJSON.asList(data["list"]) }
            completion((
                hot: [],
                list: list.map { c in
                    CommentItem(
                        nick: MusicAPIJSON.firstString(c, keys: ["user_name", "nickname"]),
                        avatar: MusicAPIJSON.firstString(c, keys: ["user_pic", "avatar"]),
                        content: MusicAPIJSON.asString(c["content"]),
                        likes: MusicAPIJSON.asInt(c["like_count"] != nil ? c["like_count"] : c["praisenum"]),
                        time: MusicAPIJSON.asInt(c["addtime"]) * 1000,
                        platform: .kg)
                }))
        }
    }

    private func commentsKw(id: String, limit: Int, page: Int, completion: @escaping ((hot: [CommentItem], list: [CommentItem])?) -> Void) {
        client.getJson(
            "https://comment.kuwo.cn/com.s?digest=0&sid=\(id)&page=\(page)&rows=\(limit)",
            headers: ["User-Agent": MusicUA.value],
            timeout: 8
        ) { json in
            guard let json = json else { completion(nil); return }
            completion((
                hot: [],
                list: MusicAPIJSON.asList(json["rows"]).map { c in
                    CommentItem(
                        nick: MusicAPIJSON.asString(c["u_name"]),
                        avatar: MusicAPIJSON.asString(c["u_pic"]),
                        content: MusicAPIJSON.asString(c["msg"]),
                        likes: MusicAPIJSON.asInt(c["like"]),
                        time: MusicAPIJSON.asInt(c["time"]) * 1000,
                        platform: .kw)
                }))
        }
    }
}
