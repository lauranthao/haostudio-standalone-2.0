/**
 * @name 新星澜音乐源
 * @description 聚合五平台多后端自动兜底的自定义音源
 * @version 0.0.14
 * @author 曦&無名&云汀（Miao-moe）
 * @homepage https://github.com/Miao-moe/Stellarwave-Music-Source
 * @tx_cookie null
 * @wy_cookie null
 * @wanfeng_key null
 * @yunmge_token null
 * @apizero_key null
 * @changelog
 *   - v0.0.14 按维护者确认：自建咪咕 H5 v2.4 的 token 原本即完整（含点号），请求时
 *     必须带上 Koneko/ynx/des 防爬请求头才能返回数据，实测已返回可播直链。新增咪咕
 *     歌曲 ID 搜索解析兜底：LX musicInfo 缺少真实 contentId 时，先经咪咕公开搜索接口
 *     按歌名+歌手匹配拿到真实 contentId/copyrightId 再请求 H5 v2.4（结果带缓存），
 *     避免 copyrightId 冒充 contentId 导致上游 500。网易后端按当日实测微调梯队顺序。
 *   - v0.0.13 按维护对话提取上游 API 重建后端链：脚本正文保持明文可读，仅将 API 密钥/Token
 *     以「XOR + Base64」加密存储，运行时解密使用；按 2026-11 实测把已验证可用的后端
 *     （酷我官方/nmobi、vkeys、HelloWorld、gdstudio(网易) 等）排到优先层；每平台保留更多
 *     兜底后端并按可用性分超时档；音质列表与脚本结构对齐洛雪官方自定义源文档（桌面+移动）。
 *   - 配置项说明：@tx_cookie / @wy_cookie 为可选平台 Cookie（解锁高音质，按账号权限）；
 *     @wanfeng_key / @yunmge_token / @apizero_key 填写后优先使用你的密钥，不填写则使用
 *     内置加密默认值。自建咪咕 H5 v2.4 为维护者固定接口，不需要用户填写。
 */
/*
 * HAo Studio 2.0 — bundled LX script (de-keyed 2026-11-23, B leg).
 * Source: Flutter 1.1.6+32 assets/lx_scripts/stellarwave014.js.
 * Removed: the whole key-vault mechanism (XOR+Base64 vault — its entries were already empty, the mechanism itself is gone: seed, alphabet, decoder, unlocker, table); NetEase EAPI key (wyEapi now throws explicitly). Kept: header @-tag user config (tx/wy cookies, wanfeng key, yunmge token, apizero key — all null/empty by default, user-fillable); fish sign uses the song id, not a secret.
 * Degradation: any backend that needed a removed key now fails its own
 * request and the script's fallback chain moves to the next backend —
 * an explicit per-backend failure, never a silent wrong result.
 * A user key is never bundled: fill it in via the script's own config
 * (showConfigView) or re-import the script yourself with your key.
 * Do not paste any key/secret/token into this file.
 */


const { EVENT_NAMES, request, on, send, utils, env, version, currentScriptInfo } = globalThis.lx

// ==================== 基础工具 ====================
const httpFetch = (url, options = {}) => new Promise((resolve, reject) => {
  request(url, options, (err, resp) => {
    if (err) return reject(err)
    let body = resp.body
    if (typeof body === 'string') {
      try { body = JSON.parse(body) } catch (e) { /* 保留原始字符串 */ }
    }
    resolve({ body, statusCode: resp.statusCode, headers: resp.headers || {} })
  })
})

// ==================== 本地 crypto 兜底 ====================
// 桌面版 LX 提供 utils.crypto（md5 / aesEncrypt），但本 App 的
// lx prelude 只给了 utils.buffer（见 lx_script_engine.dart 的
// kLxPrelude），utils.crypto 是 undefined —— wyEapi 里调 md5 会
// 抛 TypeError: cannot read property 'md5' of undefined（logcat
// 2026-11-19：md5 (<eval>) / wyEapi (<eval>:97) / fetch (<eval>:1000)，
// 就是这里）。有 utils.crypto 时照旧走它；缺失时走下面两个纯 JS
// 实现（只含算法本身，不含任何密钥），行为与桌面版一致：md5 返回
// 小写 hex；aesEncrypt 只兜底 wyEapi 用的 aes-128-ecb，返回 prelude
// 的 buffer 形态 {__haoBuf: true, bytes}，供 buf2hex 使用。
const __haoMd5 = (str) => {
  const s = unescape(encodeURIComponent(str))
  const bytes = []
  for (let i = 0; i < s.length; i++) bytes.push(s.charCodeAt(i) & 255)
  const bitLen = bytes.length * 8
  bytes.push(0x80)
  while (bytes.length % 64 !== 56) bytes.push(0)
  for (let i = 0; i < 4; i++) bytes.push((bitLen >>> (i * 8)) & 255)
  bytes.push(0, 0, 0, 0)
  const rotl = (x, n) => (x << n) | (x >>> (32 - n))
  const S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
  const K = []
  for (let i = 0; i < 64; i++) K.push(Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) >>> 0)
  let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476
  for (let off = 0; off < bytes.length; off += 64) {
    const M = []
    for (let i = 0; i < 16; i++) {
      M.push(bytes[off + i * 4] | (bytes[off + i * 4 + 1] << 8) | (bytes[off + i * 4 + 2] << 16) | (bytes[off + i * 4 + 3] << 24))
    }
    let A = a0, B = b0, C = c0, D = d0
    for (let i = 0; i < 64; i++) {
      let F, g
      if (i < 16) { F = (B & C) | (~B & D); g = i }
      else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16 }
      else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16 }
      else { F = C ^ (B | ~D); g = (7 * i) % 16 }
      F = (F + A + K[i] + M[g]) >>> 0
      A = D; D = C; C = B
      B = (B + rotl(F, S[i])) >>> 0
    }
    a0 = (a0 + A) >>> 0; b0 = (b0 + B) >>> 0; c0 = (c0 + C) >>> 0; d0 = (d0 + D) >>> 0
  }
  const hex = (x) => {
    let out = ''
    for (let i = 0; i < 4; i++) out += ('0' + ((x >>> (i * 8)) & 255).toString(16)).slice(-2)
    return out
  }
  return hex(a0) + hex(b0) + hex(c0) + hex(d0)
}

// AES-128-ECB 加密（PKCS#7 填充），data/key 为 UTF-8 字符串，返回
// prelude buffer 形态。S 盒由 GF(2^8) 逆元 + 仿射变换现算，避免
// 抄 256 字节常量表抄错。
const __haoAesSbox = (() => {
  const mul = (a, b) => {
    let p = 0
    for (let i = 0; i < 8; i++) {
      if (b & 1) p ^= a
      const hi = a & 0x80
      a = (a << 1) & 255
      if (hi) a ^= 0x1b
      b >>= 1
    }
    return p
  }
  const inv = (x) => {
    if (x === 0) return 0
    let r = 1
    for (let i = 0; i < 254; i++) r = mul(r, x)
    return r
  }
  const box = []
  for (let i = 0; i < 256; i++) {
    const y = inv(i)
    const s = y ^ ((y << 1) | (y >> 7)) ^ ((y << 2) | (y >> 6)) ^ ((y << 3) | (y >> 5)) ^ ((y << 4) | (y >> 4)) ^ 0x63
    box.push(s & 255)
  }
  return box
})()
const __haoAesEcb = (data, key) => {
  const toBytes = (str) => {
    const s = unescape(encodeURIComponent(str))
    const b = []
    for (let i = 0; i < s.length; i++) b.push(s.charCodeAt(i) & 255)
    return b
  }
  const keyB = toBytes(key)
  const dataB = toBytes(data)
  const pad = 16 - (dataB.length % 16)
  for (let i = 0; i < pad; i++) dataB.push(pad)
  const w = []
  for (let i = 0; i < 4; i++) w.push([keyB[i * 4], keyB[i * 4 + 1], keyB[i * 4 + 2], keyB[i * 4 + 3]])
  const Rcon = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]
  for (let i = 4; i < 44; i++) {
    let t = w[i - 1].slice()
    if (i % 4 === 0) {
      t = [__haoAesSbox[t[1]] ^ Rcon[i / 4 - 1], __haoAesSbox[t[2]], __haoAesSbox[t[3]], __haoAesSbox[t[0]]]
    }
    w.push([w[i - 4][0] ^ t[0], w[i - 4][1] ^ t[1], w[i - 4][2] ^ t[2], w[i - 4][3] ^ t[3]])
  }
  const xtime = (x) => ((x << 1) ^ ((x & 0x80) ? 0x1b : 0)) & 255
  const mul = (x, n) => n === 1 ? x : n === 2 ? xtime(x) : xtime(x) ^ x
  const out = []
  for (let off = 0; off < dataB.length; off += 16) {
    const s = []
    for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) s.push(dataB[off + c * 4 + r])
    const addKey = (round) => {
      for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) s[c * 4 + r] ^= w[round * 4 + c][r]
    }
    const sub = () => { for (let i = 0; i < 16; i++) s[i] = __haoAesSbox[s[i]] }
    const shift = () => {
      const t = s.slice()
      for (let r = 0; r < 4; r++) for (let c = 0; c < 4; c++) s[c * 4 + r] = t[((c + r) % 4) * 4 + r]
    }
    const mix = () => {
      for (let c = 0; c < 4; c++) {
        const a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3]
        s[c * 4] = mul(a0, 2) ^ mul(a1, 3) ^ a2 ^ a3
        s[c * 4 + 1] = a0 ^ mul(a1, 2) ^ mul(a2, 3) ^ a3
        s[c * 4 + 2] = a0 ^ a1 ^ mul(a2, 2) ^ mul(a3, 3)
        s[c * 4 + 3] = mul(a0, 3) ^ a1 ^ a2 ^ mul(a3, 2)
      }
    }
    addKey(0)
    for (let round = 1; round < 10; round++) { sub(); shift(); mix(); addKey(round) }
    sub(); shift(); addKey(10)
    for (let i = 0; i < 16; i++) out.push(s[i])
  }
  return { __haoBuf: true, bytes: out }
}

const md5 = (str) => (utils && utils.crypto ? utils.crypto.md5(str) : __haoMd5(str))

const randomGuid = () => {
  const hex = '0123456789abcdef'
  let guid = ''
  for (let i = 0; i < 32; i++) guid += hex[Math.floor(Math.random() * 16)]
  return guid
}

// Promise.any 兼容封装（移动端 JS 引擎可能未实现 ES2021 的 Promise.any）
const promiseAny = (promises) => new Promise((resolve, reject) => {
  const list = promises || []
  let pending = list.length
  const errors = new Array(pending)
  if (!pending) return reject(new Error('无可用后端'))
  list.forEach((p, i) => {
    Promise.resolve(p).then(resolve, (e) => {
      errors[i] = e
      pending -= 1
      if (!pending) reject(new Error(errors.map(x => (x && x.message) || String(x)).join('; ')))
    })
  })
})

const objToForm = (obj) => Object.keys(obj || {})
  .map(k => encodeURIComponent(k) + '=' + encodeURIComponent(obj[k]))
  .join('&')


// ==================== 头部配置解析（用户填写优先，默认值兜底） ====================
const currentScript = currentScriptInfo
  ? currentScriptInfo.rawScript
  : (typeof document !== 'undefined' ? (document.currentScript ? document.currentScript.textContent : '') : '')

const parseHeader = (str) => {
  const comment = /^\/\*\*(?:.|\n)+?\*\//.exec(str)
  const source = comment ? comment[0] : String(str || '')
  const result = {}
  const pairs = [
    { key: 'tx_cookie', regex: /\*\s*@tx_cookie\s+(.+)/ },
    { key: 'wy_cookie', regex: /\*\s*@wy_cookie\s+(.+)/ },
    { key: 'wanfeng_key', regex: /\*\s*@wanfeng_key\s+(.+)/ },
    { key: 'yunmge_token', regex: /\*\s*@yunmge_token\s+(.+)/ },
    { key: 'apizero_key', regex: /\*\s*@apizero_key\s+(.+)/ },
  ]
  for (const { key, regex } of pairs) {
    const match = regex.exec(source)
    const val = match ? match[1].trim() : ''
    result[key] = (!val || val === 'null') ? '' : val
  }
  return result
}

const config = parseHeader(currentScript)

const TX_COOKIE = config.tx_cookie
const WY_COOKIE = config.wy_cookie
const HAS_TX_COOKIE = !!TX_COOKIE
const HAS_WY_COOKIE = !!WY_COOKIE

// 用户密钥优先，内置加密默认值兜底
const WANFENG_KEY = config.wanfeng_key || ''
const YUNMGE_TOKEN = config.yunmge_token || ''
const APIZERO_KEY = config.apizero_key || ''

// 自建咪咕 H5 v2.4：维护者固定接口，带固定防爬 headers，不需要用户填写（v0.0.12 约定）
// 其余密钥（卡密/ckey/token 同样只走保险库）
const HYW_CARD_KEY = ''
const AK317_CKEY = ''
const CANXIANG_TOKEN = ''
const HYW_API_BASE = 'https://103.79.184.97' // 2026-11-25 b49fix2 (P1-9): http -> https（ATS 在真机上拦 http）

// ==================== 音质列表（对齐官方自定义源文档有效值） ====================
const MUSIC_QUALITY = {
  tx: ['128k', '320k', 'flac', 'flac24bit'],
  wy: ['128k', '320k', 'flac', 'flac24bit'],
  kw: ['128k', '320k', 'flac', 'flac24bit'],
  kg: ['128k', '320k', 'flac', 'flac24bit'],
  mg: ['128k', '320k', 'flac', 'flac24bit'],
}
const MUSIC_SOURCE = Object.keys(MUSIC_QUALITY)
const LOWEST_QUALITY = '128k'

// ==================== 各平台音质参数映射 ====================
const TX_FILE_CONFIG = {
  '128k': { s: 'M500', e: '.mp3' },
  '320k': { s: 'M800', e: '.mp3' },
  flac: { s: 'F000', e: '.flac' },
  flac24bit: { s: 'AI00', e: '.flac' },
}

const WY_LEVEL_MAP = { '128k': 'standard', '320k': 'exhigh', flac: 'lossless', flac24bit: 'hires' }

const KW_BR_MAP = { '128k': '128kmp3', '320k': '320kmp3', flac: '2000kflac', flac24bit: '4000kflac' }
const KW_STREAM_LEVEL_MAP = { '128k': '128k', '320k': '320k', flac: 'flac', flac24bit: 'flac' }
const KW_MMP_BR_MAP = { '128k': '128', '320k': '320', flac: 'flac', flac24bit: 'hires' }
const KW_APIZERO_Q_MAP = { '128k': 'h', '320k': 'p', flac: 'ff', flac24bit: 'ff' }

const KG_LEVEL_MAP = { '128k': 'standard', '320k': 'exhigh', flac: 'lossless', flac24bit: 'hires' }

const MG_TONE_FLAG_MAP = { '128k': 'PQ', '320k': 'HQ', flac: 'SQ', flac24bit: 'ZQ' }

const WY_FISH_BR_MAP = { '128k': 128, '320k': 320, flac: 740, flac24bit: 999 }

// ==================== LRU 缓存（20 分钟 / 300 条） ====================
const CACHE_TTL_MS = 1200000 // 2026-11-25 b49fix2 (P1-17): 6 小时 -> 20 分钟（签名直链会在 6 小时内过期，旧缓存会毒化播放）
const CACHE_MAX_SIZE = 300
const urlCache = new Map()

const getCachedUrl = (key) => {
  const entry = urlCache.get(key)
  if (!entry) return null
  if (Date.now() - entry.timestamp > CACHE_TTL_MS) {
    urlCache.delete(key)
    return null
  }
  urlCache.delete(key)
  urlCache.set(key, entry) // 刷新 LRU 顺序
  return entry.url
}

const setCachedUrl = (key, url) => {
  if (urlCache.has(key)) urlCache.delete(key)
  urlCache.set(key, { url, timestamp: Date.now() })
  if (urlCache.size > CACHE_MAX_SIZE) {
    const firstKey = urlCache.keys().next().value
    urlCache.delete(firstKey)
  }
}

const buildCacheKey = (source, songId, quality) => source + '_' + songId + '_' + quality

// ==================== URL 提取与过滤 ====================
const normalizeUrl = (url) => (typeof url === 'string' ? url.trim().replace(/\\u0026/g, '&') : '')

const getUrlHost = (url) => {
  const m = /^https?:\/\/([^/\s?#]+)/i.exec(String(url || ''))
  return m ? m[1].toLowerCase() : ''
}

// 通用字段提取：按候选路径依次取首个有效 URL
const extractUrl = (d, paths) => {
  if (!d) return ''
  for (const path of paths) {
    let cur = d
    let ok = true
    for (const seg of path) {
      if (cur && typeof cur === 'object' && seg in cur) cur = cur[seg]
      else { ok = false; break }
    }
    if (ok && typeof cur === 'string' && cur.startsWith('http')) return cur
  }
  return ''
}

const extractAnyPlayableUrl = (d) => extractUrl(d, [
  ['url'], ['play_url'], ['playUrl'], ['music_url'],
  ['data'], ['data', 'url'], ['data', 'play_url'], ['data', 'playUrl'], ['data', 'music_url'],
  ['data', 'data', 'url'], ['data', 'data', 'play_url'],
  ['result', 'url'], ['result', 'play_url'],
])

// 酷我部分后端会返回需要 Referer/Cookie 防盗链的地址，LX 播放器无法携带这些头，
// 这里不做绕过，只识别高风险链接并继续尝试其他后端。
const isKuwoHotlinkRiskUrl = (url) => {
  const u = normalizeUrl(url)
  const host = getUrlHost(u)
  if (!host) return true
  if (host === 'www.kuwo.cn' || host === 'kuwo.cn' || host === 'mobi.kuwo.cn' || host === 'nmobi.kuwo.cn' || host === 'antiserver.kuwo.cn') return true
  if (u.includes('/url?') || u.includes('/mobi.s') || u.includes('/anti.s')) return true
  if (/防盗链|盗链|forbidden|unauthorized/i.test(u)) return true
  return false
}

const isMiguInvalidUrl = (url) => {
  const u = normalizeUrl(url)
  if (!u) return true
  if (/防盗链|盗链|forbidden|unauthorized|无权限|会员|vip/i.test(u)) return true
  return false
}

const isPlayableUrl = (url, source = '') => {
  const u = normalizeUrl(url)
  if (!(u.startsWith('http://') || u.startsWith('https://'))) return false
  if (source === 'kw' && isKuwoHotlinkRiskUrl(u)) return false
  if (source === 'mg' && isMiguInvalidUrl(u)) return false
  return true
}

// ==================== 网易云官方 EAPI 加密 ====================
const aesEncrypt = (data, key, iv, mode) => {
  if (!version) mode = mode.split('-').pop()
  if (utils && utils.crypto) return utils.crypto.aesEncrypt(data, mode, key, iv)
  // 本 App 内 utils.crypto 缺失：只兜底 wyEapi 用的 aes-128-ecb。
  return __haoAesEcb(data, key)
}

const buf2hex = (buffer) => {
  if (version) return utils.buffer.bufToString(buffer, 'hex')
  return [...new Uint8Array(buffer)].map(x => x.toString(16).padStart(2, '0')).join('')
}

const wyEapi = (url, object) => {
  const eapiKey = ''
  if (!eapiKey) throw new Error('EAPI key removed: no bundled key (P0-15)')
  const text = typeof object === 'object' ? JSON.stringify(object) : object
  const digest = md5('nobody' + url + 'use' + text + 'md5forencrypt')
  const data = url + '-36cd479b6b5-' + text + '-36cd479b6b5-' + digest
  return { params: buf2hex(aesEncrypt(data, eapiKey, '', 'aes-128-ecb')).toUpperCase() }
}

// ==================== gdstudio 通用（网易已验证可用） ====================
// 公开接口：GET https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=&br=
// 2026-11 实测 source 仅支持 netease；其余平台由其他后端兜底。
const gdstudioNetease = async (songmid, quality) => {
  const br = WY_FISH_BR_MAP[quality]
  if (!br) throw new Error('gdstudio 不支持的音质')
  const res = await httpFetch('https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=' + encodeURIComponent(songmid) + '&br=' + br, {
    method: 'GET', timeout: 10000,
    headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)', Accept: 'application/json' },
  })
  const url = normalizeUrl(res.body && res.body.url)
  if (!url.startsWith('http')) throw new Error('gdstudio: 无数据')
  return url
}

// 旧版签名接口（music.gdstudio.xyz，2026-11 实测已无响应，保留为最后兜底）
const FISH_DOMAIN = 'music.gdstudio.xyz'
const FISH_VERSION = '20260510'
const fishSign = async (secret) => {
  const timeRes = await httpFetch('https://' + FISH_DOMAIN + '/time', { method: 'GET', timeout: 6000 })
  const timeStr = String(Number(timeRes.body) || Date.now()).slice(0, 9)
  const signInput = FISH_DOMAIN + '|' + FISH_VERSION + '|' + timeStr + '|' + secret
  return md5(signInput).slice(-8).toUpperCase()
}
const fishPost = async (params, secret) => {
  const sign = await fishSign(secret)
  params.s = sign
  const res = await httpFetch('https://' + FISH_DOMAIN + '/api.php', {
    method: 'POST', timeout: 6000,
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      Origin: 'https://' + FISH_DOMAIN,
      Referer: 'https://' + FISH_DOMAIN + '/',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'X-Requested-With': 'XMLHttpRequest',
    },
    body: objToForm(params),
  })
  return res.body
}

// ==================== HYWmusic 通用公益接口 ====================
const getHywUrl = async (source, songId, quality) => {
  const res = await httpFetch(HYW_API_BASE + '/api/music/url?source=' + source + '&songId=' + encodeURIComponent(songId) + '&quality=' + encodeURIComponent(quality) + '&key=' + encodeURIComponent(HYW_CARD_KEY), {
    method: 'GET', timeout: 8000,
    headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json', 'X-Card-Key': HYW_CARD_KEY },
  })
  const d = res.body
  if (d && d.code === 200) {
    if (d.url) return d.url
    if (d.data && d.data.url) return d.data.url
  }
  throw new Error('HYWmusic: ' + ((d && (d.message || d.msg)) || '无数据'))
}

// ==================== 星海后端（yy.zddyr.top，2026-11 实测无响应，保留兜底） ====================
const getXinghaiUrl = async (source, params) => {
  const query = objToForm(Object.assign({ source }, params))
  const res = await httpFetch('https://yy.zddyr.top/lx/api/?' + query, {
    method: 'GET', timeout: 6000,
    headers: { 'User-Agent': 'Mozilla/5.0' },
  })
  const d = res.body
  if (d && d.code === 200 && d.url) return d.url
  throw new Error('星海后端: ' + ((d && d.msg) || '无数据'))
}

// ==================== QQ 音乐后端池 ====================
const TX_BACKENDS = [
  {
    name: 'QQ官方vkey',
    fetch: async (songmid, quality) => {
      const fileInfo = TX_FILE_CONFIG[quality]
      if (!fileInfo) throw new Error('QQ官方vkey: 不支持的音质')
      const file = fileInfo.s + songmid + fileInfo.e
      const reqData = {
        req_0: {
          module: 'vkey.GetVkeyServer', method: 'CgiGetVkey',
          param: {
            filename: [file], guid: randomGuid(), songmid: [songmid], songtype: [0],
            uin: '0', loginflag: HAS_TX_COOKIE ? 1 : 0, platform: '20',
          },
        },
        loginUin: '0',
        comm: { uin: '0', format: 'json', ct: 24, cv: 0 },
      }
      const headers = { 'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0', Referer: 'https://y.qq.com/' }
      if (HAS_TX_COOKIE) headers.Cookie = TX_COOKIE
      const res = await httpFetch('https://u.y.qq.com/cgi-bin/musicu.fcg', { method: 'POST', timeout: 10000, headers, body: JSON.stringify(reqData) })
      const d = res.body
      if (d && d.req_0 && d.req_0.data && d.req_0.data.midurlinfo && d.req_0.data.midurlinfo[0] && d.req_0.data.midurlinfo[0].purl) {
        const sip = (d.req_0.data.sip && d.req_0.data.sip.length) ? d.req_0.data.sip : ['https://dl.stream.qqmusic.qq.com/']
        return sip[Math.floor(Math.random() * sip.length)] + d.req_0.data.midurlinfo[0].purl
      }
      throw new Error('QQ官方vkey: 无数据')
    },
  },
  {
    name: 'vkeys',
    fetch: async (songmid, quality) => {
      const qualityMap = { '128k': '8', '320k': '9', flac: '10', flac24bit: '16' }
      const q = qualityMap[quality]
      if (!q) throw new Error('vkeys: 不支持的音质')
      const res = await httpFetch('https://api.vkeys.cn/v2/music/tencent/geturl?mid=' + encodeURIComponent(songmid) + '&quality=' + q, {
        method: 'GET', timeout: 10000, headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' },
      })
      const d = res.body
      if (d && d.code === 200 && d.data && d.data.url) return d.data.url
      if (d && d.data && d.data.url) return d.data.url
      throw new Error('vkeys: ' + ((d && d.message) || '无数据'))
    },
  },
  {
    name: 'HelloWorld',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const name = musicInfo.name || musicInfo.songName || ''
      const singer = musicInfo.singer || ''
      const keywordText = (name + ' ' + singer).trim()
      if (!keywordText) throw new Error('HelloWorld: 缺少歌曲名')
      const keyword = encodeURIComponent(keywordText)
      const qMap = { '128k': '0', '320k': '1', flac: '4', flac24bit: '4' }
      const type = qMap[quality] || '1'
      const res = await httpFetch('https://a.aa.cab/qq.music?msg=' + keyword + '&n=1&type=' + type, {
        method: 'GET', timeout: 10000,
        headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)', Accept: 'application/json' },
      })
      const d = res.body
      const url = extractUrl(d, [['data', 'music'], ['playUrl'], ['url'], ['data', 'url']])
      if (url) return url
      throw new Error('HelloWorld: 无有效链接')
    },
  },
  {
    name: 'HYWmusic',
    fetch: async (songmid, quality) => getHywUrl('tx', songmid, quality),
  },
  {
    name: 'ygking',
    fetch: async (songmid, quality) => {
      const qMap = { '128k': '128', '320k': '320', flac: 'flac', flac24bit: 'flac24bit' }
      const res = await httpFetch('https://api.ygking.cn/api/song/url?mid=' + encodeURIComponent(songmid) + '&quality=' + (qMap[quality] || '128'), {
        method: 'GET', timeout: 6000, headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' },
      })
      const url = extractAnyPlayableUrl(res.body)
      if (url) return url
      throw new Error('ygking: 无数据')
    },
  },
  {
    name: 'FishAPI旧版',
    fetch: async (songmid, quality) => {
      const br = WY_FISH_BR_MAP[quality]
      if (!br) throw new Error('FishAPI旧版: 不支持的音质')
      const result = await fishPost({ types: 'url', id: songmid, source: 'qq', br }, encodeURIComponent(songmid))
      const url = result && result.url ? normalizeUrl(String(result.url)) : ''
      if (url.startsWith('http')) return url
      throw new Error('FishAPI旧版: 无数据')
    },
  },
  {
    name: '星海TX',
    fetch: async (songmid, quality) => getXinghaiUrl('qq', { songmid, quality }),
  },
]

// ==================== 网易云后端池 ====================
const WY_BACKENDS = [
  {
    name: '网易云官方',
    fetch: async (songmid, quality) => {
      const level = WY_LEVEL_MAP[quality] || 'standard'
      const eapiUrl = '/api/song/enhance/player/url/v1'
      const payload = { ids: [Number(songmid)], level, encodeType: 'flac', immerseType: 'c51' }
      const encrypted = wyEapi(eapiUrl, payload)
      let cookieValue = 'os=pc; appver=; osver=; deviceId=pyncm!'
      if (HAS_WY_COOKIE) cookieValue = WY_COOKIE + '; ' + cookieValue
      const res = await httpFetch('https://interface3.music.163.com/eapi/song/enhance/player/url/v1', {
        method: 'POST', timeout: 10000,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/2.10.2.200154',
          Referer: 'https://music.163.com/',
          Cookie: cookieValue,
        },
        body: 'params=' + encrypted.params,
      })
      const d = res.body
      if (d && d.data && d.data[0] && d.data[0].url && !d.data[0].freeTrialInfo) return d.data[0].url
      if (d && d.data && d.data[0] && d.data[0].freeTrialInfo) throw new Error('VIP歌曲仅试听（配置 @wy_cookie 后按账号权限获取）')
      throw new Error('网易云官方: 无数据')
    },
  },
  {
    name: 'ikun网易云',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const songId = (musicInfo.hash != null) ? musicInfo.hash : songmid
      const res = await httpFetch('https://c.wwwweb.top/music/url', {
        method: 'POST', timeout: 10000,
        headers: { 'Content-Type': 'application/json', 'User-Agent': 'lx-music-request/2.9.0' },
        body: JSON.stringify({ source: 'wy', musicId: songId, quality }),
        follow_max: 5,
      })
      const d = res.body
      if (!d || isNaN(Number(d.code))) throw new Error('ikun网易云: 未知错误')
      if (d.code === 200 && d.url) return d.url
      if (d.code === 403) throw new Error('ikun网易云: 鉴权失败')
      if (d.code === 429) throw new Error('ikun网易云: 请求过速')
      throw new Error('ikun网易云: ' + (d.message || '获取URL失败'))
    },
  },
  {
    name: 'gdstudio网易',
    fetch: async (songmid, quality) => gdstudioNetease(songmid, quality),
  },
  {
    name: 'HYWmusic',
    fetch: async (songmid, quality) => getHywUrl('wy', songmid, quality),
  },
  {
    name: '笒鬼鬼',
    fetch: async (songmid, quality) => {
      const level = WY_LEVEL_MAP[quality] || 'standard'
      const res = await httpFetch('https://api.cenguigui.cn/api/netease/music_v1.php?id=' + encodeURIComponent(songmid) + '&type=json&level=' + level, {
        method: 'GET', timeout: 8000, headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' },
      })
      const d = res.body
      if (d && d.data && d.data.url) return d.data.url
      if (d && d.url) return d.url
      throw new Error('笒鬼鬼: 无数据')
    },
  },
  {
    name: '残像WY',
    fetch: async (songmid, quality) => {
      const res = await httpFetch('https://api.canxiang.cn/api/wyymusic?token=' + encodeURIComponent(CANXIANG_TOKEN) + '&type=' + encodeURIComponent(quality) + '&id=' + encodeURIComponent(songmid), {
        method: 'GET', timeout: 6000, headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' },
      })
      const url = extractAnyPlayableUrl(res.body)
      if (url) return url
      throw new Error('残像WY: 无数据')
    },
  },
  {
    name: '星海WY',
    fetch: async (songmid, quality) => getXinghaiUrl('netease', { songmid, quality }),
  },
]

// ==================== 酷我后端池 ====================
const getKwKeyword = (musicInfo = {}, songmid = '') => {
  const name = musicInfo.name || musicInfo.songName || musicInfo.title || ''
  const singer = musicInfo.singer || musicInfo.artist || musicInfo.author || ''
  return ((name + ' ' + singer).trim()) || String(songmid || '')
}

const getKwRid = (musicInfo = {}, songmid = '') => {
  const rid = musicInfo.rid || musicInfo.musicrid || musicInfo.songmid || musicInfo.id || musicInfo.hash || songmid || ''
  return String(rid).replace(/^MUSIC_/, '').trim()
}

const KW_BACKENDS = [
  {
    name: '酷我官方',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const br = KW_BR_MAP[quality]
      if (!br) throw new Error('酷我官方: 不支持的音质')
      const rid = getKwRid(musicInfo, songmid)
      if (!rid) throw new Error('酷我官方: 缺少 rid')
      const res = await httpFetch('https://mobi.kuwo.cn/mobi.s?f=web&rid=' + encodeURIComponent(rid) + '&br=' + br + '&source=jiakong&type=convert_url_with_sign&surl=1', {
        method: 'GET', timeout: 10000, headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' },
      })
      const d = res.body
      if (d && d.code === 200 && d.data && d.data.surl) return d.data.surl
      if (d && d.code === 200 && d.data && d.data.url) return d.data.url
      throw new Error('酷我官方: 无数据')
    },
  },
  {
    name: '酷我手机版',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const br = KW_BR_MAP[quality]
      if (!br) throw new Error('酷我手机版: 不支持的音质')
      const rid = getKwRid(musicInfo, songmid)
      if (!rid) throw new Error('酷我手机版: 缺少 rid')
      const res = await httpFetch('https://nmobi.kuwo.cn/mobi.s?f=web&user=0&source=kwplayerhd_ar_4.3.0.8_tianbao_T1A_qirui.apk&type=convert_url_with_sign&rid=' + encodeURIComponent(rid) + '&br=' + br, {
        method: 'GET', timeout: 10000, headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' },
      })
      const d = res.body
      if (d && d.code === 200 && d.data && d.data.url) return d.data.url
      if (d && d.code === 200 && d.data && d.data.surl) return d.data.surl
      throw new Error('酷我手机版: 无数据')
    },
  },
  {
    name: '极数本源酷我',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const q = KW_APIZERO_Q_MAP[quality]
      if (!q) throw new Error('极数本源酷我: 不支持的音质')
      const keyword = getKwKeyword(musicInfo, songmid)
      if (!keyword) throw new Error('极数本源酷我: 缺少关键词')
      const headers = { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' }
      if (APIZERO_KEY) headers['X-Api-Key'] = APIZERO_KEY
      let musicId = String(musicInfo.rid || musicInfo.musicrid || '').replace(/^MUSIC_/, '').trim()
      if (!musicId || !/^\d+$/.test(musicId)) {
        const searchUrl = 'https://apione.apibyte.cn/kwmusic?action=search&type=music&page=0&size=5&quality=' + encodeURIComponent(q) + '&keyword=' + encodeURIComponent(keyword)
        const searchRes = await httpFetch(searchUrl, { method: 'GET', timeout: 8000, headers })
        const rows = (searchRes.body && Array.isArray(searchRes.body.data)) ? searchRes.body.data : []
        musicId = (rows[0] && (rows[0].rid || rows[0].music_id || rows[0].id)) || ''
      }
      if (!musicId) throw new Error('极数本源酷我: 缺少 music_id')
      const res = await httpFetch('https://apione.apibyte.cn/kwmusic?action=music_url&music_id=' + encodeURIComponent(musicId) + '&quality=' + encodeURIComponent(q), {
        method: 'GET', timeout: 8000, headers,
      })
      const play = extractAnyPlayableUrl(res.body)
      if (play && !isKuwoHotlinkRiskUrl(play)) return play
      throw new Error('极数本源酷我: 无可用直链')
    },
  },
  {
    name: '云萌阁酷我',
    fetch: async (songmid, quality, musicInfo = {}) => {
      if (!YUNMGE_TOKEN) throw new Error('云萌阁酷我: 未配置 token')
      const keyword = getKwKeyword(musicInfo, songmid)
      if (!keyword) throw new Error('云萌阁酷我: 缺少歌曲名')
      const res = await httpFetch('https://api.yunmge.com/api/song_kuwo?token=' + encodeURIComponent(YUNMGE_TOKEN) + '&name=' + encodeURIComponent(keyword) + '&n=1&num=10', {
        method: 'GET', timeout: 8000, headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' },
      })
      const d = res.body
      const list = (d && d.data && d.data.all_bitrates) || (d && d.all_bitrates) || []
      const prefer = quality === '128k' ? [128, '128', '128kmp3']
        : quality === '320k' ? [320, '320', '320kmp3', 128, '128kmp3']
          : [128, '128', '128kmp3', 320, '320kmp3', 2000, 'flac']
      let picked = ''
      if (Array.isArray(list)) {
        for (const p of prefer) {
          const item = list.find(x => x && (x.bitrate === p || x.label === p) && x.play_url)
          if (item) { picked = item.play_url; break }
        }
        if (!picked) {
          const first = list.find(x => x && x.play_url)
          if (first) picked = first.play_url
        }
      }
      const play = picked || extractAnyPlayableUrl(d)
      if (play && !isKuwoHotlinkRiskUrl(play)) return play
      throw new Error('云萌阁酷我: ' + ((d && d.msg) || '无可用直链'))
    },
  },
  {
    name: 'HYWmusic',
    fetch: async (songmid, quality) => getHywUrl('kw', songmid, quality),
  },
  {
    name: '晚风酷我',
    fetch: async (songmid, quality, musicInfo = {}) => {
      if (!WANFENG_KEY) throw new Error('晚风酷我: 未配置密钥')
      const rid = getKwRid(musicInfo, songmid)
      const keyword = getKwKeyword(musicInfo, songmid)
      const q = KW_APIZERO_Q_MAP[quality] || 'h'
      const key = encodeURIComponent(WANFENG_KEY)
      const candidates = [
        'https://api.nonebot.top/api/v1/kuwo?key=' + key + '&id=' + encodeURIComponent(rid) + '&quality=' + encodeURIComponent(q),
        'https://api.nonebot.top/api/v1/music/kuwo?key=' + key + '&id=' + encodeURIComponent(rid) + '&quality=' + encodeURIComponent(q),
        'https://api.nonebot.top/api/v1/music/url?key=' + key + '&source=kw&songId=' + encodeURIComponent(rid) + '&quality=' + encodeURIComponent(quality),
        'https://api.nonebot.top/api/v1/kuwo?key=' + key + '&name=' + encodeURIComponent(keyword) + '&quality=' + encodeURIComponent(q),
      ]
      const errors = []
      for (const api of candidates) {
        try {
          const res = await httpFetch(api, { method: 'GET', timeout: 6000, headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' } })
          const play = extractAnyPlayableUrl(res.body)
          if (play && !isKuwoHotlinkRiskUrl(play)) return play
          errors.push('无直链')
        } catch (e) {
          errors.push((e && e.message) || String(e))
        }
      }
      throw new Error('晚风酷我: ' + errors.join('; '))
    },
  },
  {
    name: '远梦酷我(mmp)',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const br = KW_MMP_BR_MAP[quality]
      if (!br) throw new Error('远梦酷我: 不支持的音质')
      const keyword = getKwKeyword(musicInfo, songmid)
      if (!keyword) throw new Error('远梦酷我: 缺少关键词')
      const res = await httpFetch('https://api.mmp.cc/api/kuwo?action=search_song&msg=' + encodeURIComponent(keyword) + '&pageSize=5&br=' + encodeURIComponent(br), {
        method: 'GET', timeout: 6000, headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' },
      })
      const d = res.body
      const play = extractAnyPlayableUrl(d)
      if (play && !isKuwoHotlinkRiskUrl(play)) return play
      throw new Error('远梦酷我: ' + ((d && d.msg) || '无可用直链'))
    },
  },
  {
    name: '星海KW',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const name = musicInfo.name || ''
      const singer = musicInfo.singer || ''
      return getXinghaiUrl('kw', { name, singer, songmid, quality })
    },
  },
]

// ==================== 酷狗后端池 ====================
const KG_BACKENDS = [
  {
    name: '酷狗官方',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const hash = musicInfo.hash || musicInfo.songmid || songmid
      if (!hash) throw new Error('酷狗官方: 缺少 hash')
      const albumId = musicInfo.albumId || ''
      const res = await httpFetch('https://wwwapi.kugou.com/yy/index.php?r=play/getdata&hash=' + encodeURIComponent(hash) + '&platid=4&album_id=' + encodeURIComponent(albumId) + '&mid=00000000000000000000000000000000', {
        method: 'GET', timeout: 10000,
        headers: { 'User-Agent': 'Mozilla/5.0', Referer: 'https://www.kugou.com/' },
      })
      const d = res.body
      if (d && d.status === 1 && d.data && d.data.play_backup_url) return d.data.play_backup_url
      if (d && d.status === 1 && d.data && d.data.play_url) return d.data.play_url
      throw new Error('酷狗官方: 无数据')
    },
  },
  {
    name: 'HYWmusic',
    fetch: async (songmid, quality) => getHywUrl('kg', songmid, quality),
  },
  {
    name: '长青海棠',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const level = KG_LEVEL_MAP[quality] || 'standard'
      const hash = musicInfo.hash || musicInfo.songmid || songmid
      const res = await httpFetch('https://musicserver.haitangw.cc/v1/music/resolve-url', {
        method: 'POST', timeout: 6000,
        headers: { 'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0' },
        body: JSON.stringify({ source: 'kg', rid: hash, level }),
      })
      const d = res.body
      if (d && d.code === 0 && d.data && d.data.url) return d.data.url
      throw new Error('长青海棠: ' + ((d && d.msg) || '无数据'))
    },
  },
  {
    name: '星海KG',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const hash = musicInfo.hash || musicInfo.songmid || songmid
      return getXinghaiUrl('kg', { songmid: hash, quality })
    },
  },
]

// ==================== 咪咕后端池 ====================
const extractMiguUrl = (d) => extractUrl(d, [
  ['url'], ['playUrl'], ['play_url'],
  ['data'], ['data', 'url'], ['data', 'playUrl'], ['data', 'play_url'],
  ['data', 'data', 'url'], ['data', 'data', 'playUrl'],
  ['data', 'walkmanInfo', 'playUrl'], ['walkmanInfo', 'playUrl'],
  ['result', 'url'], ['result', 'playUrl'],
])

const getMiguContentIds = (musicInfo = {}, fallback = '') => {
  const contentId = musicInfo.contentId || musicInfo.content_id || musicInfo.contentid || musicInfo.songId || musicInfo.songid || musicInfo.id || fallback
  const copyrightId = musicInfo.copyrightId || musicInfo.copyright_id || musicInfo.copyrightid || musicInfo.songmid || musicInfo.hash || fallback
  return { contentId: String(contentId || '').trim(), copyrightId: String(copyrightId || '').trim() }
}





const MG_BACKENDS = [
  {
    name: 'Migu直接源',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const level = MG_TONE_FLAG_MAP[quality] || 'PQ'
      const ids = getMiguContentIds(musicInfo, songmid)
      const copyrightId = ids.copyrightId || songmid
      const res = await httpFetch('https://music.migu.cn/v3/api/music/audioPlayer/getPlayInfo?copyrightId=' + encodeURIComponent(copyrightId) + '&type=1&level=' + level, {
        method: 'GET', timeout: 8000,
        headers: { 'User-Agent': 'Mozilla/5.0', Referer: 'https://music.migu.cn/' },
      })
      const d = res.body
      const play = extractMiguUrl(d)
      if (play && !isMiguInvalidUrl(play)) return play
      throw new Error('Migu直接源: 无数据')
    },
  },
  {
    name: 'Migu API',
    fetch: async (songmid, quality, musicInfo = {}) => {
      const qualityParam = MG_TONE_FLAG_MAP[quality] || 'PQ'
      const ids = getMiguContentIds(musicInfo, songmid)
      const copyrightId = ids.copyrightId || songmid
      const res = await httpFetch('https://app.c.nf.migu.cn/MIGUM2.0/strategy/listen-url/v2.2?copyrightId=' + encodeURIComponent(copyrightId) + '&quality=' + qualityParam, {
        method: 'GET', timeout: 8000,
        headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json', Referer: 'https://app.c.nf.migu.cn/' },
      })
      const d = res.body
      const play = extractMiguUrl(d)
      if (play && !isMiguInvalidUrl(play)) return play
      throw new Error('Migu API: ' + ((d && (d.info || d.msg)) || '无数据'))
    },
  },
  {
    name: 'HYWmusic',
    fetch: async (songmid, quality) => getHywUrl('mg', songmid, quality),
  },
  {
    name: '星海咪咕',
    fetch: async (songmid, quality) => getXinghaiUrl('migu', { songmid, quality }),
  },
]

// ==================== 歌曲 ID 提取与音质候选 ====================
const getSongIdBySource = (source, musicInfo = {}) => {
  if (source === 'kw') return getKwRid(musicInfo)
  if (source === 'kg') return musicInfo.hash || musicInfo.songmid || musicInfo.id || musicInfo.albumAudioId || ''
  if (source === 'mg') return musicInfo.copyrightId || musicInfo.copyright_id || musicInfo.contentId || musicInfo.songmid || musicInfo.id || musicInfo.hash || ''
  if (source === 'tx') return musicInfo.songmid || musicInfo.mediaMid || musicInfo.strMediaMid || musicInfo.id || musicInfo.hash || ''
  if (source === 'wy') return musicInfo.hash || musicInfo.songmid || musicInfo.id || '' // LX 网易源 hash 即数字 id
  return musicInfo.hash || musicInfo.songmid || musicInfo.id || ''
}

const QUALITY_FALLBACK_ORDER = {
  tx: ['128k', '320k', 'flac', 'flac24bit'],
  wy: ['128k', '320k', 'flac', 'flac24bit'],
  kw: ['128k', '320k', 'flac', 'flac24bit'],
  kg: ['128k', '320k', 'flac', 'flac24bit'],
  mg: ['128k', '320k', 'flac', 'flac24bit'],
}

const uniq = (arr) => {
  const list = []
  for (const item of arr) {
    if (item && !list.includes(item)) list.push(item)
  }
  return list
}

const getQualityCandidates = (source, requestedQuality) => {
  const supported = MUSIC_QUALITY[source] || [LOWEST_QUALITY]
  const base = QUALITY_FALLBACK_ORDER[source] || [LOWEST_QUALITY]
  let requested = supported.includes(requestedQuality) ? requestedQuality : LOWEST_QUALITY
  // 网易云：无 Cookie 时优先普通音质，避免先请求会员高音质导致失败变慢
  if (source === 'wy' && !HAS_WY_COOKIE) requested = LOWEST_QUALITY
  const candidates = uniq([requested, LOWEST_QUALITY].concat(base)).filter(q => supported.includes(q))
  return candidates.length ? candidates : [supported[0] || LOWEST_QUALITY]
}

// ==================== 核心请求（缓存 + 分批并发兜底） ====================
const handleGetMusicUrl = async (source, musicInfo = {}, quality = LOWEST_QUALITY) => {
  let songId = getSongIdBySource(source, musicInfo)
  // 2026-11-25 b49fix2 (P2-34): 删掉 mg 的 'search:' + 歌名兜底 — 没有
  // 任何 mg 后端认 search: 前缀，它只会被 URL 编码进 copyrightId= 参数
  // 然后每个后端都失败，白白烧掉任务预算。缺 id 就如实抛错。
  if (!songId) throw new Error('无法获取歌曲ID')

  const backends = { tx: TX_BACKENDS, wy: WY_BACKENDS, kw: KW_BACKENDS, kg: KG_BACKENDS, mg: MG_BACKENDS }[source]
  if (!backends || !backends.length) throw new Error('未知音源或没有可用后端: ' + source)

  const qualityCandidates = getQualityCandidates(source, quality)
  const errors = []

  for (const targetQuality of qualityCandidates) {
    const cacheKey = buildCacheKey(source, songId, targetQuality)
    const cached = getCachedUrl(cacheKey)
    if (cached) {
      console.log('[新星澜] 缓存命中: ' + source + ' ' + songId + ' ' + targetQuality)
      // 2026-11-25 b49fix2 (P1-15): 缓存里存的就是 {url, quality} 对象。
      return cached
    }

    // 第一梯队：前两个后端并发竞速，降低整体等待
    try {
      const result = await promiseAny(backends.slice(0, 2).map(async (backend) => {
        const url = await backend.fetch(songId, targetQuality, musicInfo)
        if (isPlayableUrl(url, source)) return normalizeUrl(url)
        throw new Error(backend.name + ' 返回无效URL')
      }))
      // 2026-11-25 b49fix2 (P1-15): 返回 {url, quality}，按实际命中的
      // 降级档位标；缓存里存对象。
      const firstResult = { url: normalizeUrl(result), quality: targetQuality }
      setCachedUrl(cacheKey, firstResult)
      return firstResult
    } catch (err) {
      if (err && err.message) errors.push(targetQuality + ' 梯队1: ' + err.message)
    }

    // 第二梯队：剩余后端顺序尝试（按 2026-11 实测可用性排序）
    for (const backend of backends.slice(2)) {
      try {
        const url = await backend.fetch(songId, targetQuality, musicInfo)
        if (isPlayableUrl(url, source)) {
          const clean = { url: normalizeUrl(url), quality: targetQuality }
          setCachedUrl(cacheKey, clean)
          return clean
        }
        errors.push(targetQuality + ' ' + backend.name + ': 返回无效URL')
      } catch (e) {
        errors.push(targetQuality + ' ' + backend.name + ': ' + ((e && e.message) || e))
      }
    }
  }

  throw new Error('所有后端均失败，已尝试音质：' + qualityCandidates.join(', ') + '\n' + errors.join('\n'))
}

// ==================== 事件注册 ====================
on(EVENT_NAMES.request, ({ action, source, info }) => {
  switch (action) {
    case 'musicUrl':
      return handleGetMusicUrl(source, info.musicInfo, info.type)
        .then(url => Promise.resolve(url))
        .catch(err => Promise.reject(err))
    default:
      return Promise.reject(new Error('action not support: ' + action))
  }
})

// ==================== 初始化 ====================
const musicSources = {}
const SOURCE_NAME_MAP = { tx: 'QQ音乐', wy: '网易云音乐', kw: '酷我音乐', kg: '酷狗音乐', mg: '咪咕音乐' }
MUSIC_SOURCE.forEach((item) => {
  musicSources[item] = {
    name: SOURCE_NAME_MAP[item] || item,
    type: 'music',
    actions: ['musicUrl'],
    qualitys: MUSIC_QUALITY[item],
  }
})

send(EVENT_NAMES.inited, { openDevTools: false, sources: musicSources })

console.log('[新星澜] v0.0.14 音乐源已加载完成 (' + (env || 'unknown') + ')')
console.log('[新星澜] 平台: ' + MUSIC_SOURCE.join(', '))
console.log('[新星澜] QQ后端数: ' + TX_BACKENDS.length + ' | 网易: ' + WY_BACKENDS.length + ' | 酷我: ' + KW_BACKENDS.length + ' | 酷狗: ' + KG_BACKENDS.length + ' | 咪咕: ' + MG_BACKENDS.length)
