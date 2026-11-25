/*!
 * @name 👖裤佬SVIP音源(二改整合版)
 * @description 基于安妮独家音源v4 + 星海音乐源v3.2.12 重构，替代原不稳定版本
 * @description 官网 https://Jsnzkpg.github.io
 * @version v3.0.0 | 2026-08-19
 * @author 裤佬 | 安妮 | 星海
 */
/*
 * HAo Studio 2.0 — bundled LX script (de-keyed 2026-11-23, B leg).
 * Source: Flutter 1.1.6+32 assets/lx_scripts/kuliao.js.
 * Audited: no plaintext key/secret/token found in this script. Tokens it uses are generated at runtime (server-issued or device-derived) or left empty for the user to fill in.
 * Degradation: any backend that needed a removed key now fails its own
 * request and the script's fallback chain moves to the next backend —
 * an explicit per-backend failure, never a silent wrong result.
 * A user key is never bundled: fill it in via the script's own config
 * (showConfigView) or re-import the script yourself with your key.
 * Do not paste any key/secret/token into this file.
 */


const { EVENT_NAMES, request, on, send, env, version } = globalThis.lx;

// ==================== 配置区 ====================
// 若需使用星海ChKSz接口，填入apikey（留空则跳过）
const CHKSZ_APIKEY = '';

// 酷我代理解密配置
const KW_DECRYPT_PROXY = {
  url: '',
  allowEncryptedLossless: false,
  urlParamName: 'url',
  ekeyParamName: 'ekey'
};

// ==================== 常量定义 ====================
const PLATFORMS = ['wy', 'tx', 'kw', 'kg', 'mg'];
const PLATFORM_NAMES = {
  wy: '网易云音乐', tx: 'QQ音乐', kw: '酷我音乐', kg: '酷狗音乐', mg: '咪咕音乐'
};

// 各平台支持的音质
const MUSIC_QUALITIES = {
  wy: ['128k', '192k', '320k', 'flac', 'flac24bit', 'hires', 'jyeffect', 'sky', 'jymaster'],
  tx: ['128k', '192k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'master'],
  kw: ['128k', '320k', 'flac', 'flac24bit', 'hires'],
  kg: ['128k', '320k', 'flac', 'flac24bit', 'hires'],
  mg: ['128k', '320k', 'flac', 'flac24bit']
};

// 音质降级顺序
const QUALITY_ORDER = ['jymaster', 'sky', 'jyeffect', 'master', 'hires', 'flac24bit', 'atmos', 'flac', '320k', '192k', '128k'];

// 2026-11-25 b49fix2 (P1-15): 向引擎报告的档位必须是引擎档位表里的值
// （'128k','320k','flac','flac24bit','hires','master'）。网易臻品档位
// （jymaster/sky/jyeffect）与全景声（atmos/atmos_plus）不在表里：
// 臻品母带/臻品音质是无损 24bit 级，报 master；臻品音质 AI 报 hires；
// 全景声是多声道有损，保守报 320k，不冒充无损。
const ENGINE_TIERS = ['128k', '320k', 'flac', 'flac24bit', 'hires', 'master'];
const TIER_ALIAS = { '192k': '128k', jymaster: 'master', sky: 'master', jyeffect: 'hires', atmos: '320k', atmos_plus: '320k' };
function reportTier(q, fallback) {
  if (q == null) return fallback;
  if (TIER_ALIAS[q]) return TIER_ALIAS[q];
  return ENGINE_TIERS.includes(q) ? q : fallback;
}
// GD br -> 实际档位（br=999 最高只出 flac24bit，740 是 flac）
const GD_BR_QUALITY = { '999': 'flac24bit', '740': 'flac', '320': '320k', '192': '128k', '128': '128k' };

// ==================== API 端点 ====================
const API = {
  // 安妮 - 酷狗代理
  kgAnnie: 'https://api.music.lerd.dpdns.org/kg',
  // 安妮 - QQ vkeys
  txVkeys: 'https://api.vkeys.cn/v2/music/tencent/geturl',
  // 安妮 - 酷我
  kwMobi: 'https://nmobi.kuwo.cn/mobi.s', // 2026-11-25 b49fix2 (P1-9): http -> https（ATS 在真机上拦 http）
  // 安妮 - 网易
  wyWeb: 'https://c.wwwweb.top/music/url',
  // 星海 - 后端主接口
  xhBackend: 'https://yy.zddyr.top/lx/api/',
  // 星海 - 后端备用
  xhBackendFallback: 'https://zrcdy.dpdns.org/lx/api/',
  // 星海 - GD Studio
  gdStudio: 'https://music-api.gdstudio.xyz/api.php',
  // 星海 - ChKSz
  chkszWy: 'https://api.chksz.com/api/163_music',
  chkszTx: 'https://api.chksz.com/api/qq_music',
  // 裤佬 - QSVIP搜索
  qsVip: 'https://api.qs.vip/music/',
  qsVipFallback: 'https://api.qs.la/music/'
};

// ==================== 质量映射 ====================
const QUALITY_MAP = {
  kg: { '128k': '128k', '320k': '320k', 'flac': 'flac', 'flac24bit': 'flac24bit', 'hires': 'flac24bit' },
  tx: { '128k': '6', '192k': '7', '320k': '8', 'flac': '10', 'flac24bit': '11', 'hires': '11', 'atmos': '13', 'master': '14' },
  kw: { '128k': '128kmp3', '320k': '320kmp3', 'flac': '2000kflac', 'flac24bit': '4000kflac', 'hires': '4000kflac' },
  wy: { '128k': '128k', '192k': '128k', '320k': '320k', 'flac': 'flac', 'flac24bit': 'flac24bit', 'hires': 'hires', 'jyeffect': 'hires', 'sky': 'atmos', 'jymaster': 'master' },
  mg: { '128k': '128k', '320k': '320k', 'flac': 'flac', 'flac24bit': 'flac24bit' }
};

const GD_BR_MAP = { '128k': '128', '192k': '192', '320k': '320', 'flac': '740', 'flac24bit': '999', 'hires': '999' };
const CHKSZ_WY_LEVEL = { '128k': 'standard', '192k': 'exhigh', '320k': 'exhigh', 'flac': 'lossless', 'flac24bit': 'hires', 'hires': 'hires', 'jyeffect': 'jyeffect', 'sky': 'sky', 'jymaster': 'jymaster' };
const CHKSZ_TX_SIZE = { '128k': '128k', '192k': '320k', '320k': '320k', 'flac': 'flac', 'flac24bit': 'hires', 'hires': 'hires', 'atmos': 'master', 'master': 'master' };

// ==================== 工具函数 ====================
const httpFetch = (url, options = {}) => new Promise((resolve, reject) => {
  request(url, { timeout: 5000, ...options }, (err, resp) => {
    if (err) return reject(err);
    let body = resp.body;
    if (typeof body === 'string') {
      const t = body.trim();
      if (t.startsWith('{') || t.startsWith('[')) {
        try { body = JSON.parse(t); } catch (e) {}
      }
    }
    resolve({ statusCode: resp.statusCode, headers: resp.headers || {}, body });
  });
});

function mapQuality(quality, avail) {
  if (avail.includes(quality)) return quality;
  for (const q of QUALITY_ORDER) {
    if (avail.includes(q)) return q;
  }
  return avail[0] || '128k';
}

// ==================== 各平台URL解析器 ====================

/* ---- 酷狗（安妮代理） ---- */
async function resolveKgAnnie(info, quality) {
  const hash = info.SQFileHash || info.HQFileHash || info.FileHash || info.hash || info.songmid;
  if (!hash) throw new Error('缺少酷狗歌曲hash');
  const type = QUALITY_MAP.kg[quality] || '128k';
  const resp = await httpFetch(API.kgAnnie, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ type, musicInfo: { source: 'kg', hash } })
  });
  if (resp.body?.code === 200 && resp.body?.data?.url) return resp.body.data.url;
  throw new Error(resp.body?.message || `酷狗安妮获取失败(code:${resp.body?.code})`);
}

/* ---- QQ（安妮vkeys） ---- */
async function resolveTxVkeys(info, quality) {
  const mid = info.songmid;
  if (!mid) throw new Error('缺少QQ songmid');
  const qc = QUALITY_MAP.tx[quality] || '6';
  const resp = await httpFetch(`${API.txVkeys}?mid=${mid}&quality=${qc}`);
  if (resp.body?.code === 200 && resp.body?.data?.url) return resp.body.data.url;
  throw new Error(resp.body?.message || `QQ vkeys获取失败(code:${resp.body?.code})`);
}

/* ---- 酷我（安妮mobi） ---- */
async function resolveKwMobi(info, quality) {
  const rid = info.rid || info.hash || info.songmid || info.id;
  if (!rid) throw new Error('缺少酷我歌曲ID');
  const br = QUALITY_MAP.kw[quality];
  if (!br) throw new Error('不支持的酷我音质');
  const params = {
    f: 'web', user: '0',
    source: 'kwplayerhd_ar_4.3.0.8_tianbao_T1A_qirui.apk',
    type: 'convert_url_with_sign', rid, br
  };
  const qs = Object.keys(params).map(k => `${k}=${encodeURIComponent(params[k])}`).join('&');
  const resp = await httpFetch(`${API.kwMobi}?${qs}`);
  if (resp.body?.code === 200 && resp.body?.data?.url) return resp.body.data.url;
  throw new Error(resp.body?.msg || `酷我mobi获取失败(code:${resp.body?.code})`);
}

/* ---- 网易（安妮c.wwwweb.top） ---- */
async function resolveWyWeb(info, quality) {
  const id = info.songmid || info.id || info.hash;
  if (!id) throw new Error('缺少网易歌曲ID');
  const level = QUALITY_MAP.wy[quality] || 'flac';
  const resp = await httpFetch(API.wyWeb, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: { source: 'wy', musicId: id, quality: level }
  });
  const b = resp.body;
  if (b?.code === 200 && b?.url) return b.url;
  throw new Error(b?.message || `网易web获取失败(code:${b?.code})`);
}

/* ---- 星海后端接口（多平台通用） ---- */
async function resolveXhBackend(platform, info, quality, baseUrl) {
  const sourceMap = { wy: 'netease', tx: 'qq', kw: 'kw', kg: 'kg', mg: 'migu' };
  const source = sourceMap[platform] || platform;
  const params = { source, quality: quality || '' };
  params.songmid = info.songmid || info.id || '';
  params.name = info.name || '';
  params.singer = info.singer || '';
  params.albumName = info.albumName || info.album || '';
  params.interval = info.interval || '';

  if (platform === 'kg') {
    const types = info._types || {};
    params.mainHash = info.hash || '';
    if (types[quality]?.hash) params.hash = types[quality].hash;
    params.albumId = info.albumId || '';
  }

  const qs = Object.keys(params).map(k => `${encodeURIComponent(k)}=${encodeURIComponent(params[k])}`).join('&');
  const url = `${baseUrl}?${qs}`;
  const resp = await httpFetch(url);
  const data = resp.body;
  if (data?.code === 200 && data?.url) {
    // 2026-11-25 b49fix2 (P1-15): 后端自报的档位只在档位表里才采信，
    // 否则返回 null，由调用方按请求的档位标。
    const servedQuality = reportTier(data.quality, null);
    // 处理酷我加密链接
    if (platform === 'kw' && KW_DECRYPT_PROXY.allowEncryptedLossless && data.ekey && KW_DECRYPT_PROXY.url) {
      return { url: `${KW_DECRYPT_PROXY.url}?${KW_DECRYPT_PROXY.urlParamName}=${encodeURIComponent(data.url)}&${KW_DECRYPT_PROXY.ekeyParamName}=${encodeURIComponent(data.ekey)}`, quality: servedQuality };
    }
    return { url: data.url, quality: servedQuality };
  }
  throw new Error(data?.msg || `星海后端获取失败(code:${data?.code})`);
}

/* ---- 星海GD Studio（网易高音质） ---- */
async function resolveWyGdStudio(info, quality) {
  const id = info.songmid || info.id || info.hash;
  if (!id) throw new Error('缺少网易歌曲ID');
  const br = GD_BR_MAP[quality] || '320';
  const url = `${API.gdStudio}?use_xbridge3=true&loader_name=forest&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease&id=${id}&br=${br}`;
  const resp = await httpFetch(url);
  // 2026-11-25 b49fix2 (P1-15): 按实际请求的 br 标档位；740 兜底是 flac。
  if (resp.body?.url) return { url: resp.body.url, quality: GD_BR_QUALITY[String(br)] || '128k' };
  // 若hires失败回退到flac
  if (quality === 'hires' || quality === 'flac24bit') {
    const fallbackUrl = `${API.gdStudio}?use_xbridge3=true&loader_name=forest&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease&id=${id}&br=740`;
    const resp2 = await httpFetch(fallbackUrl);
    if (resp2.body?.url) return { url: resp2.body.url, quality: 'flac' };
  }
  throw new Error(resp.body?.msg || 'GD Studio获取失败');
}

/* ---- 星海ChKSz（网易SVIP/QQ高音质） ---- */
async function resolveWyChksz(info, quality) {
  if (!CHKSZ_APIKEY) throw new Error('ChKSz未配置apikey');
  const id = info.songmid || info.id || info.hash;
  if (!id) throw new Error('缺少网易歌曲ID');
  const level = CHKSZ_WY_LEVEL[quality];
  if (!level) throw new Error(`ChKSz不支持网易音质:${quality}`);
  const resp = await httpFetch(`${API.chkszWy}?id=${id}&level=${level}&apikey=${encodeURIComponent(CHKSZ_APIKEY)}`);
  if (resp.body?.code === 200 && resp.body?.data?.url) return resp.body.data.url;
  throw new Error(resp.body?.msg || 'ChKSz网易获取失败');
}

async function resolveTxChksz(info, quality) {
  if (!CHKSZ_APIKEY) throw new Error('ChKSz未配置apikey');
  const mid = info.songmid || info.id;
  if (!mid) throw new Error('缺少QQ mid');
  const size = CHKSZ_TX_SIZE[quality];
  if (!size) throw new Error(`ChKSz不支持QQ音质:${quality}`);
  const resp = await httpFetch(`${API.chkszTx}?mid=${mid}&size=${size}&type=json&apikey=${encodeURIComponent(CHKSZ_APIKEY)}`);
  if (resp.body?.code === 200 && resp.body?.url) return resp.body.url;
  throw new Error(resp.body?.msg || 'ChKSz QQ获取失败');
}

/* ---- 裤佬QSVIP搜索 ---- */
async function searchQsVip(keywords, page = 1, pageSize = 30) {
  if (!keywords) return { isEnd: true, list: [] };
  const urls = [API.qsVip, API.qsVipFallback];
  let lastErr = null;
  for (const baseUrl of urls) {
    try {
      const url = `${baseUrl}?act=search&keywords=${encodeURIComponent(keywords)}&page=${page}&pagesize=${pageSize}&type=music`;
      const resp = await httpFetch(url);
      const data = resp.body;
      if (data?.code === 200 && Array.isArray(data?.data?.list)) {
        // 2026-11-25 b49fix2 (P2-30): 以前 id/songmid/hash 全填 QSVIP
        // 自己的 id，任何按 id 取流的腿都解不出来，只能靠歌名+歌手
        // 兜底。QSVIP 条目若自带平台原生 id（songmid/mid/hash/rid），
        // 保留它；没有才回落到 QSVIP id。
        const list = data.data.list.map(item => ({
          id: item.songmid || item.mid || item.hash || item.rid || item.id || '',
          songmid: item.songmid || item.mid || item.id || '',
          hash: item.hash || item.rid || item.id || '',
          rid: item.rid || item.songmid || item.id || '',
          name: item.name || '',
          singer: item.singer || item.artist || '',
          albumName: item.albumName || item.album || '',
          duration: item.duration || 0,
          pic: item.pic || item.cover || ''
        }));
        const total = Number(data.data.total) || list.length;
        return { isEnd: list.length < pageSize, list, total };
      }
      lastErr = new Error(data?.msg || 'QSVIP搜索异常');
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr || new Error('QSVIP搜索全部失败');
}

// ==================== 核心：获取音乐URL ====================
async function fetchMusicUrl(platform, info, quality) {
  const actualQuality = mapQuality(quality, MUSIC_QUALITIES[platform] || ['128k', '320k', 'flac']);
  const id = info.hash || info.songmid || info.id;
  if (!id) throw new Error('缺少歌曲标识符');

  // 按平台定义回退链
  const chains = {
    wy: [
      { name: 'ChKSz网易', fn: () => resolveWyChksz(info, actualQuality) },
      { name: 'GD Studio', fn: () => resolveWyGdStudio(info, actualQuality) },
      { name: 'c.wwwweb.top', fn: () => resolveWyWeb(info, actualQuality) },
      { name: '星海后端', fn: () => resolveXhBackend('wy', info, actualQuality, API.xhBackend) },
      { name: '星海后端(备)', fn: () => resolveXhBackend('wy', info, actualQuality, API.xhBackendFallback) }
    ],
    tx: [
      { name: 'ChKSz QQ', fn: () => resolveTxChksz(info, actualQuality) },
      { name: 'vkeys QQ', fn: () => resolveTxVkeys(info, actualQuality) },
      { name: '星海后端', fn: () => resolveXhBackend('tx', info, actualQuality, API.xhBackend) },
      { name: '星海后端(备)', fn: () => resolveXhBackend('tx', info, actualQuality, API.xhBackendFallback) }
    ],
    kw: [
      { name: '星海后端', fn: () => resolveXhBackend('kw', info, actualQuality, API.xhBackend) },
      { name: '酷我mobi', fn: () => resolveKwMobi(info, actualQuality) },
      { name: '星海后端(备)', fn: () => resolveXhBackend('kw', info, actualQuality, API.xhBackendFallback) }
    ],
    kg: [
      { name: '酷狗安妮', fn: () => resolveKgAnnie(info, actualQuality) },
      { name: '星海后端', fn: () => resolveXhBackend('kg', info, actualQuality, API.xhBackend) },
      { name: '星海后端(备)', fn: () => resolveXhBackend('kg', info, actualQuality, API.xhBackendFallback) }
    ],
    mg: [
      { name: '星海后端', fn: () => resolveXhBackend('mg', info, actualQuality, API.xhBackend) },
      { name: '星海后端(备)', fn: () => resolveXhBackend('mg', info, actualQuality, API.xhBackendFallback) }
    ]
  };

  const chain = chains[platform];
  if (!chain) throw new Error(`不支持的平台: ${platform}`);

  const errors = [];
  for (const provider of chain) {
    try {
      // 2026-11-25 b49fix2 (P1-15): 解析器返回裸字符串或 {url, quality}；
      // 有自报档位就用它，否则按本次请求的档位标。
      const result = await provider.fn();
      const url = typeof result === 'string' ? result : result?.url;
      if (typeof url === 'string' && url.startsWith('http')) {
        const served = typeof result === 'object' ? reportTier(result.quality, null) : null;
        return { url, quality: reportTier(served, reportTier(actualQuality, '128k')) };
      }
      errors.push(`${provider.name}: 返回无效URL`);
    } catch (e) {
      errors.push(`${provider.name}: ${e.message}`);
    }
  }
  throw new Error(`所有接口均失败: ${errors.join('; ')}`);
}

// ==================== 事件处理 ====================
on(EVENT_NAMES.request, async ({ action, source, info }) => {
  if (!source || !PLATFORMS.includes(source)) {
    throw new Error(`不支持的音乐源: ${source}`);
  }

  // 搜索
  if (action === 'search') {
    const keywords = info?.text || '';
    const page = info?.page || 1;
    const pageSize = info?.limit || 30;
    return searchQsVip(keywords, page, pageSize);
  }

  // 获取音乐URL
  if (action === 'musicUrl') {
    if (!info?.musicInfo || !info?.type) throw new Error('参数不完整');
    return fetchMusicUrl(source, info.musicInfo, info.type);
  }

  // 歌词（暂未实现独立歌词API，返回空）
  if (action === 'lyric') {
    return { lyric: '', tlyric: '' };
  }

  // 封面图
  if (action === 'pic') {
    const id = info?.musicInfo?.hash || info?.musicInfo?.songmid || info?.musicInfo?.id;
    return null;
  }

  throw new Error(`不支持的操作: ${action}`);
});

// ==================== 启动 ====================
const sources = {};
PLATFORMS.forEach(p => {
  sources[p] = {
    name: PLATFORM_NAMES[p],
    type: 'music',
    actions: ['search', 'musicUrl', 'lyric', 'pic'],
    qualitys: MUSIC_QUALITIES[p]
  };
});

send(EVENT_NAMES.inited, {
  status: true,
  openDevTools: false,
  sources
});