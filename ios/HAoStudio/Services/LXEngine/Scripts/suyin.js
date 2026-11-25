/*!
 * @name 溯音音源
 * @description 集成网易、咪咕音乐平台 ，QQ群1078955749
 * 2026-11-25 b49fix2 (P1-12): QQ/酷我腿已删除 — oiapi.net 的 QQ_Music
 * 与 Kuwo 端点已下线（实测 code -13001 / -2），不是缺 key。
 * @version v1
 * @author 竹佀
 */
/*
 * HAo Studio 2.0 — bundled LX script (de-keyed 2026-11-23, B leg).
 * Source: Flutter 1.1.6+32 assets/lx_scripts/suyin.js.
 * Audited: no plaintext key/secret/token found in this script. Tokens it uses are generated at runtime (server-issued or device-derived) or left empty for the user to fill in.
 * Degradation: any backend that needed a removed key now fails its own
 * request and the script's fallback chain moves to the next backend —
 * an explicit per-backend failure, never a silent wrong result.
 * A user key is never bundled: fill it in via the script's own config
 * (showConfigView) or re-import the script yourself with your key.
 * Do not paste any key/secret/token into this file.
 */


const { EVENT_NAMES, request, on, send } = globalThis.lx


// ========== 缓存配置 ==========
const cache = new Map()
const CACHE_TTL = 300000 // 5分钟缓存


// ========== 主事件处理器 ==========
on(EVENT_NAMES.request, async ({ action, source, info }) => {
    try {
        switch (action) {
            case 'musicUrl':
                return await handleMusicUrl(source, info)
            case 'search':
                return await handleSearch(source, info)
            default:
                throw new Error('不支持的操作')
        }
    } catch (error) {
        console.error(`[溯音音源] ${source} ${action} 错误:`, error.message)
        throw error
    }
})

// ========== 获取音乐URL ==========
async function handleMusicUrl(source, info) {
    if (!info?.musicInfo) throw new Error('需要歌曲信息')

    const musicInfo = info.musicInfo
    const quality = info.type || '128k'

    switch (source) {
        // 2026-11-25 b49fix2 (P1-12): tx/kw 已删除（oiapi QQ/Kuwo 端点下线）
        case 'wy':
            return await getWyMusicUrl(musicInfo)
        case 'mg':
            return await getMgMusicUrl(musicInfo)
        default:
            throw new Error('不支持的平台')
    }
}





// ========== 网易云音乐模块 ==========
async function getWyMusicUrl(musicInfo) {
    const songId = musicInfo.songmid || musicInfo.id
    if (!songId) throw new Error('缺少ID')

    const data = await sendRequest(`https://oiapi.net/api/Music_163?id=${songId}`)

    if (data.code === 0 && data.data) {
        // oiapi now returns data as a Map {items:[{url,...}]}; the old
        // shape was a bare List. Accept both (same as the built-in
        // oiapi_wy resolver — fixed 2026-11-24, build-35真播放重验:
        // the old code read data.data.url off the Map and always threw
        // '获取失败' even though the API answered).
        let song = null
        if (Array.isArray(data.data)) song = data.data[0]
        else if (Array.isArray(data.data.items)) song = data.data.items[0]
        else song = data.data
        if (song && song.url) return song.url
    }
    throw new Error('获取失败')
}






// ========== 咪咕音乐模块 ==========
async function getMgMusicUrl(musicInfo) {
    if (!musicInfo.name) throw new Error('需要歌曲名称')

    const cacheKey = `mg_${musicInfo.name}_${musicInfo.albumName || ''}_${musicInfo.singer || ''}`
    if (cache.has(cacheKey)) {
        const cached = cache.get(cacheKey)
        if (Date.now() - cached.timestamp < CACHE_TTL) {
            return cached.url
        }
    }

    const searchPriority = getSearchPriority(musicInfo)

    for (const term of searchPriority) {
        try {
            console.log(`[溯音音源-咪咕] 尝试搜索: ${term.keyword} (严格: ${term.strict})`)
            const data = await sendRequest('https://api.xcvts.cn/api/music/migu', {
                gm: term.keyword,
                n: 1,
                num: 1,
                type: 'json'
            })

            if (data.code === 200 && data.music_url) {
                if (term.strict && !checkMgMatch(data, musicInfo)) {
                    console.log(`[溯音音源-咪咕] 信息不匹配: ${data.title} vs ${musicInfo.name}`)
                    throw new Error('歌曲信息不匹配')
                }

                cache.set(cacheKey, { url: data.music_url, timestamp: Date.now() })
                return data.music_url
            }
        } catch (error) {
            console.log(`[溯音音源-咪咕] 搜索失败: ${term.keyword} - ${error.message}`)
        }
    }

    throw new Error('未找到咪咕音乐链接')
}

function checkMgMatch(apiData, musicInfo) {
    const apiTitle = (apiData.title || '').toLowerCase()
    const apiArtist = (apiData.artist || '').toLowerCase()
    const apiAlbum = (apiData.album || '').toLowerCase()

    const songName = (musicInfo.name || '').toLowerCase()
    const singer = (musicInfo.singer || '').toLowerCase()
    const album = ((musicInfo.albumName || musicInfo.album) || '').toLowerCase()

    if (!apiTitle.includes(songName) && !songName.includes(apiTitle)) {
        return false
    }

    if (album && apiAlbum && !apiAlbum.includes(album) && !album.includes(apiAlbum)) {
        return false
    }

    if (singer && apiArtist && !apiArtist.includes(singer) && !singer.includes(apiArtist)) {
        return false
    }

    return true
}

// ========== 搜索功能 ==========
async function handleSearch(source, info) {
    if (!info?.keyword) throw new Error('需要搜索关键词')

    const keyword = info.keyword.trim()
    const page = info.page || 1
    const limit = Math.min(info.limit || 20, 30)

    switch (source) {
        case 'mg':
            return await searchMgMusic(keyword, page, limit)
        default:
            throw new Error('该平台不支持搜索')
    }
}


async function searchMgMusic(keyword, page, limit) {
    const results = []

    for (let i = page; i <= page + 2 && results.length < limit; i++) {
        try {
            const data = await sendRequest('https://api.xcvts.cn/api/music/migu', {
                gm: keyword,
                n: i,
                num: 1,
                type: 'json'
            })

            if (data.code === 200) {
                // 2026-11-25 b49fix2 (P1-11): 咪咕曲目 id 必须是后端返回的
                // 真实 id（contentId），不能用随机串 — 随机 id 播放时后端
                // 无法取流。缺失时用歌名+歌手派生（仍可按名搜索解析）。
                const realId = data.id != null && data.id !== ''
                    ? String(data.id)
                    : ('mg_' + cleanText(data.title || keyword) + '_' + cleanText(data.artist || ''))
                results.push({
                    name: data.title || keyword,
                    singer: data.artist || '',
                    albumName: data.album || '',
                    id: realId,
                    source: 'mg',
                    interval: data.duration || '00:00',
                    meta: { mg: { id: data.id != null ? String(data.id) : '' } }
                })
            }
        } catch { }
    }

    if (results.length === 0) throw new Error('未找到相关歌曲')
    return results
}

// ========== 核心工具函数 ==========
function getSearchPriority(musicInfo) {
    const priority = []

    // 第一优先级：歌名 + 专辑
    if (musicInfo.albumName || musicInfo.album) {
        const album = musicInfo.albumName || musicInfo.album
        const keyword = cleanText(musicInfo.name + album)
        if (keyword) {
            priority.push({
                keyword: keyword,
                strict: true,
                type: 'name+album'
            })
        }
    }

    // 第二优先级：歌名 + 歌手
    if (musicInfo.singer) {
        const keyword = cleanText(musicInfo.name + musicInfo.singer)
        if (keyword) {
            priority.push({
                keyword: keyword,
                strict: true,
                type: 'name+singer'
            })
        }
    }

    // 第三优先级：仅歌名
    const keyword = cleanText(musicInfo.name)
    if (keyword) {
        priority.push({
            keyword: keyword,
            strict: false,
            type: 'name'
        })
    }

    return priority
}


function sendRequest(baseUrl, params = {}) {
    return new Promise((resolve, reject) => {
        const query = Object.keys(params)
            .map(k => `${k}=${encodeURIComponent(params[k])}`)
            .join('&')
        const url = `${baseUrl}${query ? '?' + query : ''}`

        request(url, {
            method: 'GET',
            timeout: 8000
        }, (err, resp) => {
            if (err) {
                reject(new Error(`请求失败: ${err.message}`))
                return
            }

            try {
                const data = typeof resp.body === 'string' ? JSON.parse(resp.body) : resp.body
                resolve(data)
            } catch (e) {
                reject(new Error('响应格式错误'))
            }
        })
    })
}

function cleanText(text) {
    if (!text) return ''
    return text
        .replace(/\(\s*Live\s*\)/gi, '')
        .replace(/\([^)]*\)/g, '')
        .replace(/\s+/g, '')
        .replace(/[^\w\u4e00-\u9fa5]/g, '')
        .trim()
}

// ========== 初始化 ==========
const registeredSources = {
    wy: {
        name: '网易云音乐',
        type: 'music',
        actions: ['musicUrl'],
        qualitys: ['128k', '320k', 'flac']
    },
    mg: {
        name: '咪咕音乐',
        type: 'music',
        actions: ['musicUrl', 'search'],
        qualitys: ['128k', '320k'],
        supportSearchSuggestions: false
    }
}

send(EVENT_NAMES.inited, {
    openDevTools: false,
    sources: registeredSources
})

console.log('[溯音音源] v1 已加载 - 支持网易、咪咕音乐')