/*!
 * @name 非常刀
 * @description 聚合音源，进群链接 https://t.me/gydjlfk
 * @version v5
 * @author 群主要进去
 */
/*
 * HAo Studio 2.0 — bundled LX script (de-keyed 2026-11-23, B leg).
 * Source: Flutter 1.1.6+32 assets/lx_scripts/feichangdao.js.
 * Audited: no plaintext key/secret/token found in this script. Tokens it uses are generated at runtime (server-issued or device-derived) or left empty for the user to fill in.
 * Degradation: any backend that needed a removed key now fails its own
 * request and the script's fallback chain moves to the next backend —
 * an explicit per-backend failure, never a silent wrong result.
 * A user key is never bundled: fill it in via the script's own config
 * (showConfigView) or re-import the script yourself with your key.
 * Do not paste any key/secret/token into this file.
 */


const { EVENT_NAMES, request, on, send } = globalThis.lx

// ========== API 端点 ==========
const CHKSZ_API = 'https://api.chksz.com/api' // 2026-11-25 b49fix2 (P2-38): .top 已 404，改 .com（仍需 apikey，设计如此）
const XINGHAI_API = 'https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest&need_sec_link=1&sec_link_scene=im&theme=light'
const SUYIN_163_API = 'https://oiapi.net/api/Music_163'
const SUYIN_MG_API = 'https://api.xcvts.cn/api/music/migu'
const QISHUI_SEARCH_API = 'https://api-vehicle.volcengine.com/v2/search/type'
const QISHUI_H5_API = 'https://api.qishui.com/luna/h5/track'

// ========== 音质映射 ==========
const CHKSZ_LEVEL = { '128k': 'standard', '320k': 'exhigh', 'flac': 'lossless', 'flac24bit': 'jymaster' }
const CHKSZ_FALLBACK = {
  jymaster: ['jymaster', 'lossless', 'exhigh', 'standard'],
  lossless: ['lossless', 'exhigh', 'standard'],
  exhigh: ['exhigh', 'standard'],
  standard: ['standard'],
}
// chksz level -> 实际音质档位（降级命中时如实上报）
const CHKSZ_LEVEL_QUALITY = { standard: '128k', exhigh: '320k', lossless: 'flac', jymaster: 'flac24bit' }
const XINGHAI_BR = { '128k': '128', '192k': '192', '320k': '320', 'flac': '740', 'flac24bit': '999' }
const XINGHAI_SRC = { wy: 'netease' } // 2026-11-25 b49fix2 (P1-13): gdstudio 只认 netease，其余 source 一律 400


// ========== 缓存 ==========
const cache = new Map()
const CACHE_TTL = 300000
const CACHE_MAX = 200

function cacheGet(key) {
  const c = cache.get(key)
  if (!c) return null
  if (Date.now() - c.ts > CACHE_TTL) { cache.delete(key); return null }
  return c.val
}

function cacheSet(key, val) {
  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value)
  cache.set(key, { val, ts: Date.now() })
}

// ========== 工具函数 ==========
function httpGet(url, { timeout = 10000, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    request(url, { method: 'GET', timeout, headers: { Accept: 'application/json', ...headers } }, (err, resp) => {
      if (err) return reject(new Error(err.message))
      try {
        resolve(typeof resp.body === 'string' ? JSON.parse(resp.body) : resp.body)
      } catch { reject(new Error('响应解析失败')) }
    })
  })
}

function validateUrl(url) {
  if (typeof url === 'string' && /^https?:\/\//.test(url)) return url
  throw new Error('无效URL')
}

function getSongId(info) {
  return (info.hash || info.songmid || info.id || info.rid || info.songId || '').toString()
}



function cleanText(text) {
  if (!text) return ''
  return text.replace(/（[^）]*）/g, '').replace(/\([^)]*\)/g, '').replace(/\[[^\]]*\]/g, '')
    .replace(/\s+/g, '').replace(/[【】《》"""'''·,，。!！?？:：;；/\\|\-]/g, '').trim().toLowerCase()
}

function formatDuration(ms) {
  const sec = typeof ms === 'number' ? Math.floor(ms > 1000 ? ms / 1000 : ms) : 0
  if (sec <= 0) return '00:00'
  return `${Math.floor(sec / 60).toString().padStart(2, '0')}:${(sec % 60).toString().padStart(2, '0')}`
}

function buildSearchKeywords(info) {
  const kws = []
  if (info.singer) kws.push({ kw: `${info.name} ${info.singer}`, strict: true })
  if (info.albumName || info.album) kws.push({ kw: `${info.name} ${info.albumName || info.album}`, strict: true })
  kws.push({ kw: info.name, strict: false })
  return kws
}

function checkSongMatch(apiName, apiArtist, musicInfo) {
  const a = cleanText(apiName), b = cleanText(musicInfo.name || '')
  if (!a || !b || (!a.includes(b) && !b.includes(a))) return false
  const singer = cleanText(musicInfo.singer || '')
  if (singer) {
    const c = cleanText(apiArtist || '')
    if (c && !c.includes(singer) && !singer.includes(c)) return false
  }
  return true
}

// ========== Provider: CHKSZ (网易云) ==========
async function chkszGetUrl(info, quality) {
  const level = CHKSZ_LEVEL[quality] || 'standard'
  const levels = CHKSZ_FALLBACK[level] || ['standard']
  const id = getSongId(info)
  if (!id) throw new Error('缺少ID')
  for (const lv of levels) {
    try {
      const body = await httpGet(`${CHKSZ_API}/163_music?id=${id}&level=${lv}`, { headers: { Referer: 'https://cp.chksz.top/' } })
      // 2026-11-25 b49fix2 (P1-15): 降级命中哪个 level 就报哪个档位。
      if (body?.code === 200 && body.data?.url) return { url: body.data.url, quality: CHKSZ_LEVEL_QUALITY[lv] || '128k' }
    } catch { continue }
  }
  throw new Error('CHKSZ失败')
}

// ========== Provider: 星海 (全平台) ==========
async function xinghaiGetUrl(platform, info, quality) {
  const source = XINGHAI_SRC[platform]
  const br = XINGHAI_BR[quality] || '320'
  const id = getSongId(info)
  if (!source || !id) throw new Error('参数缺失')
  const body = await httpGet(`${XINGHAI_API}&types=url&source=${source}&id=${encodeURIComponent(id)}&br=${br}`)
  return validateUrl(body?.url)
}



// ========== Provider: 溯音163 ==========
async function suyin163GetUrl(info) {
  const id = getSongId(info)
  if (!id) throw new Error('缺少ID')
  const body = await httpGet(`${SUYIN_163_API}?id=${id}`)
  const data = Array.isArray(body?.data) ? body.data[0] : body?.data
  return validateUrl(data?.url)
}


// ========== Provider: 溯音咪咕 (搜索式) ==========
async function suyinMgGetUrl(info) {
  for (const { kw, strict } of buildSearchKeywords(info)) {
    try {
      const body = await httpGet(`${SUYIN_MG_API}?gm=${encodeURIComponent(kw)}&n=1&num=1&type=json`)
      if (body?.code === 200 && body?.music_url) {
        if (!strict || checkSongMatch(body.title || '', body.artist || '', info))
          return validateUrl(body.music_url)
      }
    } catch { continue }
  }
  throw new Error('溯音咪咕失败')
}


// ========== Provider: 汽水H5 (免费直链) ==========
async function qishuiH5GetUrl(info) {
  const id = getSongId(info)
  if (!id) throw new Error('缺少ID')
  const body = await httpGet(`${QISHUI_H5_API}?track_id=${id}`)
  const songStr = body?.track_player?.video_model
  if (!songStr) throw new Error('汽水H5无数据')
  const song = JSON.parse(songStr).video_list?.[0]
  if (!song?.main_url) throw new Error('汽水H5无链接')
  return validateUrl(song.main_url)
}

// ========== 回退链 ==========
// 2026-11-25 b49fix2 (P1-12/P1-13): tx/kw/kg 已无存活后端，整条链删除 —
// 溯音QQ/酷我端点下线，星海腿只认 netease，长青/念心模板全 404/401。
// 只剩 wy [CHKSZ, 星海, 溯音163]、mg [溯音咪咕]、qs [汽水H5]。
const CHAINS = {
  wy: [
    { name: 'CHKSZ', fn: (si, q) => chkszGetUrl(si, q) },
    { name: '星海', fn: (si, q) => xinghaiGetUrl('wy', si, q) },
    { name: '溯音163', fn: (si, q) => suyin163GetUrl(si) },
  ],
  mg: [
    { name: '溯音咪咕', fn: (si, q) => suyinMgGetUrl(si) },
  ],
  qs: [
    { name: '汽水H5', fn: (si, q) => qishuiH5GetUrl(si) },
  ],
}

// 2026-11-25 b49fix2 (P1-15): 统一归一化为 {url, quality}；裸字符串
// 的后端记 quality: null（档位未知，引擎保留请求档位）。
function toUrlResult(r) {
  if (typeof r === 'string') return { url: validateUrl(r), quality: null }
  return { url: validateUrl(r.url), quality: r.quality || null }
}

async function getUrlWithFallback(platform, songInfo, quality) {
  const chain = CHAINS[platform]
  if (!chain) throw new Error('不支持的平台')

  const key = `url_${platform}_${getSongId(songInfo)}_${quality}`
  const cached = cacheGet(key)
  if (cached) return cached

  // Phase 1: 前3个源并发竞速
  const concurrent = chain.slice(0, 3)
  try {
    const result = await Promise.any(concurrent.map(s => s.fn(songInfo, quality).then(toUrlResult)))
    cacheSet(key, result)
    return result
  } catch {}

  // Phase 2: 剩余源顺序尝试
  for (const s of chain.slice(3)) {
    try {
      const result = toUrlResult(await s.fn(songInfo, quality))
      cacheSet(key, result)
      return result
    } catch { continue }
  }

  throw new Error('所有音源均失败')
}

// ========== 事件处理 ==========
on(EVENT_NAMES.request, async ({ action, source, info }) => {
  try {
    switch (action) {
      case 'musicUrl': return await handleMusicUrl(source, info)
      case 'search': return await handleSearch(source, info)
      case 'lyric': return await handleLyric(source, info)
      default: throw new Error('不支持的操作')
    }
  } catch (error) {
    console.error(`[非常刀] ${source} ${action} 错误:`, error.message)
    throw error
  }
})

async function handleMusicUrl(source, info) {
  if (!info?.musicInfo) throw new Error('需要歌曲信息')
  return await getUrlWithFallback(source, info.musicInfo, info.type || '128k')
}

// ========== 搜索 ==========
async function handleSearch(source, info) {
  if (!info?.keyword) throw new Error('需要搜索关键词')
  const keyword = info.keyword.trim()
  const limit = Math.min(info.limit || 20, 30)

  switch (source) {
    case 'wy': return await searchChksz(keyword, limit)
    case 'mg': return await searchMigu(keyword, limit)
    case 'qs': return await searchQishui(keyword, limit)
    default: throw new Error('该平台不支持搜索')
  }
}

async function searchChksz(keyword, limit) {
  const body = await httpGet(`${CHKSZ_API}/163_search?keyword=${encodeURIComponent(keyword)}&limit=${limit}`, { headers: { Referer: 'https://cp.chksz.top/' } })
  if (body?.code !== 200) throw new Error('搜索失败')
  const items = Array.isArray(body.data) ? body.data : (body.data?.songs || [])
  if (!items.length) throw new Error('未找到相关歌曲')
  return items.slice(0, limit).map(s => ({
    name: s.name || '', singer: s.artists || '',
    albumName: typeof s.album === 'string' ? s.album : (s.album?.name || ''),
    id: s.id, source: 'wy', interval: formatDuration(s.duration),
    meta: { picture: s.picUrl || '', wy: { id: s.id, url_id: s.id, lyric_id: s.id } }
  }))
}


async function searchMigu(keyword, limit) {
  const results = []
  for (let page = 1; results.length < limit && page <= 3; page++) {
    try {
      const body = await httpGet(`${SUYIN_MG_API}?gm=${encodeURIComponent(keyword)}&n=${page}&num=1&type=json`)
      if (body?.code !== 200 || !body.title) break
      // 2026-11-25 b49fix2 (P1-11): 咪咕曲目 id 必须是后端返回的真实 id，
      // 不能用随机串 — 随机 id 播放时后端无法取流。
      const realId = body.id != null && body.id !== ''
        ? String(body.id)
        : ('mg_' + cleanText(body.title || '') + '_' + cleanText(body.artist || ''))
      results.push({
        name: body.title || '', singer: body.artist || '', albumName: body.album || '',
        id: realId, source: 'mg', interval: body.duration || '00:00',
        meta: { mg: { id: body.id != null ? String(body.id) : '' } }
      })
    } catch { break }
  }
  if (!results.length) throw new Error('未找到相关歌曲')
  return results
}

// ========== 歌词 ==========
async function handleLyric(source, info) {
  if (source !== 'qs') throw new Error('该平台不支持歌词')
  const id = getSongId(info?.musicInfo || {})
  if (!id) throw new Error('缺少ID')
  const body = await httpGet(`${QISHUI_H5_API}?track_id=${id}`)
  const raw = body?.lyric?.content || ''
  if (!raw) throw new Error('无歌词')
  return { lyric: krcToLrc(raw) }
}

function krcToLrc(krc) {
  const lines = krc.split('\n')
  const result = []
  for (const line of lines) {
    const m = line.match(/^\[(\d+),(\d+)\](.*)$/)
    if (!m) continue
    const startMs = parseInt(m[1])
    const min = Math.floor(startMs / 60000)
    const sec = Math.floor((startMs % 60000) / 1000)
    const ms = Math.floor((startMs % 1000) / 10)
    const text = m[3].replace(/<\d+,\d+,\d+>/g, '')
    if (text.trim()) result.push(`[${String(min).padStart(2,'0')}:${String(sec).padStart(2,'0')}.${String(ms).padStart(2,'0')}]${text}`)
  }
  return result.join('\n')
}

async function searchQishui(keyword, limit) {
  const body = await httpGet(`${QISHUI_SEARCH_API}?keyword=${encodeURIComponent(keyword)}&search_type=music&limit=${limit}&real_offset=0&search_source=qishui`)
  const items = body?.data?.list
  if (!Array.isArray(items) || !items.length) throw new Error('未找到相关歌曲')
  return items.slice(0, limit).map(s => ({
    name: s.title || '', singer: s.author_info?.name || '', albumName: '',
    id: s.item_id, source: 'qs', interval: formatDuration(s.duration),
    img: s.cover_url || '',
    meta: { picture: s.cover_url || '', qs: { id: s.item_id } }
  }))
}

// ========== 初始化 ==========
send(EVENT_NAMES.inited, {
  openDevTools: false,
  sources: {
    wy: { name: '网易云音乐', type: 'music', actions: ['musicUrl', 'search'], qualitys: ['128k', '320k', 'flac', 'flac24bit'], defaultQuality: 'flac' },
    mg: { name: '咪咕音乐', type: 'music', actions: ['musicUrl', 'search'], qualitys: ['128k', '320k', 'flac'] },
    qs: { name: '汽水音乐', type: 'music', actions: ['musicUrl', 'search', 'lyric'], qualitys: ['128k'] },
  }
})

console.log('[非常刀] v4 已加载 - 网易/咪咕/汽水 多源聚合')