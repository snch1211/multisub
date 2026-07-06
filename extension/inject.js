// Runs in the page's main world (injected by content.js at document_start).
//
// Responsibilities:
//  1. Hook JSON.stringify so Netflix's manifest request also asks for the
//     WebVTT subtitle profile (much easier to parse than TTML).
//  2. Hook JSON.parse to capture the manifest response, which contains the
//     full list of timed-text tracks (with download URLs) for the episode.
//  3. On request from the content script, fetch a track, parse it into
//     cues [{start, end, text}], and post them back via window.postMessage.
(() => {
  'use strict';
  if (window.__multisubInjected) return;
  window.__multisubInjected = true;

  const WEBVTT_PROFILE = 'webvtt-lssdh-ios8';

  // Debug logging for A3 interception diagnosis. Set to false once resolved.
  const DEBUG = false;
  function dbg() {
    if (!DEBUG) return;
    try { console.log.apply(console, ['[MultiSub][inject]'].concat([].slice.call(arguments))); } catch (e) { /* ignore */ }
  }
  function safeJson(x, n) {
    try { const s = JSON.stringify(x); return (s === undefined ? String(x) : s).slice(0, n || 400); }
    catch (e) { return '<unstringifiable>'; }
  }
  dbg('page-world script loaded at', location.pathname);

  // Depth-limited walk to report where movieId / timedtexttracks live in a
  // parsed payload, so we can fix scanForManifest() against the real shape.
  function debugDescribeManifest(root) {
    try {
      const seen = new Set();
      const stack = [{ v: root, path: '$' }];
      let steps = 0;
      while (stack.length && steps < 5000) {
        steps++;
        const item = stack.pop();
        const v = item.v;
        if (!v || typeof v !== 'object' || seen.has(v)) continue;
        seen.add(v);
        if (v.movieId != null) {
          dbg('  node@', item.path, 'movieId=', v.movieId, 'ALLKEYS=', Object.keys(v).join(','));
          // Dump the structure of any key that might hold subtitle / text tracks.
          for (const k of Object.keys(v)) {
            if (!/text|subtitle|caption|timed|\bcc\b|track/i.test(k)) continue;
            const val = v[k];
            if (Array.isArray(val)) {
              const e0 = val[0];
              dbg('    KEY', k, '= Array(' + val.length + ') elem0keys=',
                  (e0 && typeof e0 === 'object') ? Object.keys(e0).join(',') : typeof e0,
                  ' elem0=', safeJson(e0, 600));
            } else if (val && typeof val === 'object') {
              dbg('    KEY', k, '= Object keys=', Object.keys(val).join(','),
                  ' sample=', safeJson(val, 400));
            }
          }
        }
        if (Array.isArray(v)) {
          for (let i = 0; i < v.length && i < 60; i++) stack.push({ v: v[i], path: item.path + '[' + i + ']' });
        } else {
          for (const k of Object.keys(v)) if (k.length < 40) stack.push({ v: v[k], path: item.path + '.' + k });
        }
      }
    } catch (e) { dbg('describe error', e && e.message); }
  }

  function post(msg) {
    window.postMessage(Object.assign({ __multisub: true }, msg), '*');
  }

  // movieId (string) -> [{id, language, label, forced, trackType, format, url}]
  const trackCache = new Map();

  // ---------------------------------------------------------------------------
  // Hook JSON.stringify: add the WebVTT profile to Netflix manifest requests.
  // Manifest requests are identified by having a params.profiles array of
  // audio/video profile strings.
  // ---------------------------------------------------------------------------
  const origStringify = JSON.stringify;
  JSON.stringify = function (value) {
    try {
      const profiles = value && value.params && value.params.profiles;
      if (Array.isArray(profiles)) {
        const matched = profiles.some((p) => typeof p === 'string' && /^(heaac|playready|dfxp|simplesdh|imsc)/.test(p));
        dbg('stringify: params.profiles seen, matched=', matched, 'sample=', profiles.slice(0, 8));
        if (matched && !profiles.includes(WEBVTT_PROFILE)) {
          profiles.push(WEBVTT_PROFILE);
          dbg('stringify: injected', WEBVTT_PROFILE);
        }
      }
    } catch (e) { /* never break the page */ }
    return origStringify.apply(this, arguments);
  };

  // ---------------------------------------------------------------------------
  // Hook JSON.parse: capture manifest responses (movieId + timedtexttracks).
  // ---------------------------------------------------------------------------
  const origParse = JSON.parse;
  JSON.parse = function () {
    const value = origParse.apply(this, arguments);
    try {
      if (DEBUG) {
        const raw = arguments[0];
        if (typeof raw === 'string' &&
            (raw.indexOf('timedtexttracks') !== -1 || raw.indexOf('"movieId"') !== -1)) {
          dbg('parse: manifest-ish payload len=', raw.length,
              'hasTimedText=', raw.indexOf('timedtexttracks') !== -1);
          debugDescribeManifest(value);
        }
      }
      scanForManifest(value);
    } catch (e) { /* ignore */ }
    return value;
  };

  function scanForManifest(value) {
    if (!value || typeof value !== 'object') return;
    const candidates = [];
    if (value.result) {
      if (Array.isArray(value.result)) candidates.push.apply(candidates, value.result);
      else candidates.push(value.result);
    }
    candidates.push(value);
    for (const c of candidates) {
      // Netflix renamed `timedtexttracks` -> `textTracks` (2024/25 manifest);
      // accept either so old and new manifests both work.
      if (c && c.movieId && (Array.isArray(c.textTracks) || Array.isArray(c.timedtexttracks))) {
        handleManifest(c);
        return;
      }
    }
  }

  function extractUrl(downloadable) {
    if (!downloadable) return null;
    if (typeof downloadable === 'string') return downloadable;
    if (Array.isArray(downloadable.urls) && downloadable.urls.length) {
      const first = downloadable.urls[0];
      return typeof first === 'string' ? first : (first.url || first.cdnUrl || null);
    }
    if (downloadable.downloadUrls) {
      const keys = Object.keys(downloadable.downloadUrls);
      if (keys.length) return downloadable.downloadUrls[keys[0]];
    }
    if (typeof downloadable.url === 'string') return downloadable.url;
    if (typeof downloadable.cdnUrl === 'string') return downloadable.cdnUrl;
    return null;
  }

  function handleManifest(manifest) {
    const list = Array.isArray(manifest.textTracks) ? manifest.textTracks
               : (manifest.timedtexttracks || []);
    if (DEBUG && list.length) {
      const t0 = list[0] || {};
      dbg('handleManifest: track list len=', list.length, 'track0 keys=', Object.keys(t0).join(','),
          'downloadables?', safeJson(t0.ttDownloadables || t0.downloadables, 500));
    }
    const tracks = [];
    for (const t of list) {
      if (t.isNoneTrack || t.isNone) continue;
      const downloadables = t.ttDownloadables || t.downloadables || {};
      let profile = null;
      let format = null;
      if (downloadables[WEBVTT_PROFILE]) {
        profile = WEBVTT_PROFILE;
        format = 'webvtt';
      } else {
        // Pick a webvtt-ish profile if present, else fall back to the first (TTML/imsc).
        const keys = Object.keys(downloadables);
        profile = keys.find((k) => /webvtt|vtt/i.test(k)) || keys[0];
        if (profile) format = /webvtt|vtt/i.test(profile) ? 'webvtt' : 'ttml';
      }
      if (!profile) continue;
      const url = extractUrl(downloadables[profile]);
      if (!url) continue;
      tracks.push({
        id: (t.new_track_id || t.language || 'track') + ':' + (t.rawTrackType || t.trackType || '') + ':' + tracks.length,
        language: t.language || '',
        label: t.languageDescription || t.language || 'unknown',
        forced: !!t.isForcedNarrative,
        trackType: t.rawTrackType || t.trackType || '',
        format: format,
        url: url
      });
    }
    dbg('handleManifest: movieId=', manifest.movieId, 'usable tracks=', tracks.length,
        'formats=', tracks.map((t) => t.format));
    if (!tracks.length) return;
    const movieId = String(manifest.movieId);
    trackCache.set(movieId, tracks);
    // Don't leak URLs to the content script; it asks back by trackId.
    post({
      type: 'tracks',
      movieId: movieId,
      tracks: tracks.map((t) => ({
        id: t.id, language: t.language, label: t.label,
        forced: t.forced, trackType: t.trackType, format: t.format
      }))
    });
  }

  // ---------------------------------------------------------------------------
  // T1: detect the subtitle track currently selected in the Netflix player UI
  // (method a from PLAN.md — private player API), so content.js can auto-
  // follow it instead of guessing. This is reverse-engineered, undocumented
  // API: every access is inside the try/catch below, and any failure just
  // stops this feature from reporting (content.js keeps its existing
  // heuristic track pick as the de-facto fallback — method b, a full DOM/cue
  // diff comparator, is not implemented; not worth the complexity unless
  // method a is observed to actually break).
  // ---------------------------------------------------------------------------
  const lastActiveTrackSig = new Map(); // movieId -> "bcp47|displayName" signature

  function pollActiveTrack() {
    try {
      const playerApp = window.netflix && window.netflix.appContext &&
        window.netflix.appContext.state && window.netflix.appContext.state.playerApp;
      const api = playerApp && playerApp.getAPI && playerApp.getAPI();
      const videoPlayer = api && api.videoPlayer;
      if (!videoPlayer || typeof videoPlayer.getAllPlayerSessionIds !== 'function') return;
      const sessionIds = videoPlayer.getAllPlayerSessionIds();
      for (const sessionId of sessionIds) {
        const player = videoPlayer.getVideoPlayerBySessionId(sessionId);
        if (!player || typeof player.getTimedTextTrack !== 'function') continue;
        const movieId = typeof player.getMovieId === 'function' ? player.getMovieId() : null;
        if (movieId == null) continue;
        const track = player.getTimedTextTrack();
        let bcp47 = null;
        let displayName = null;
        if (track && !track.isNoneTrack) {
          bcp47 = track.bcp47Code || track.bcp47 || track.language || null;
          displayName = track.displayName || track.trackDisplayName || null;
        }
        if (DEBUG) dbg('pollActiveTrack: session=', sessionId, 'movieId=', movieId, 'rawTrack=', safeJson(track, 300));
        const movieIdStr = String(movieId);
        const sig = bcp47 + '|' + displayName;
        if (lastActiveTrackSig.get(movieIdStr) === sig) continue;
        lastActiveTrackSig.set(movieIdStr, sig);
        dbg('active-track changed:', movieIdStr, bcp47, displayName);
        post({ type: 'active-track', movieId: movieIdStr, bcp47: bcp47, displayName: displayName });
      }
    } catch (e) {
      dbg('pollActiveTrack error (Netflix player API likely changed):', e && e.message);
    }
  }

  setInterval(pollActiveTrack, 750);

  // ---------------------------------------------------------------------------
  // Commands from the content script.
  // ---------------------------------------------------------------------------
  window.addEventListener('message', (ev) => {
    const msg = ev.data;
    if (!msg || msg.__multisub_cmd !== true) return;
    if (msg.type === 'fetch-track') fetchTrack(String(msg.movieId), msg.trackId, msg.purpose);
    else if (msg.type === 'get-tracks') {
      const tracks = trackCache.get(String(msg.movieId));
      if (tracks) {
        post({
          type: 'tracks',
          movieId: String(msg.movieId),
          tracks: tracks.map((t) => ({
            id: t.id, language: t.language, label: t.label,
            forced: t.forced, trackType: t.trackType, format: t.format
          }))
        });
      }
    } else if (msg.type === 'get-title') {
      const info = getVideoTitle(msg.movieId) ||
        { seriesTitle: null, episodeTitle: null, seasonNumber: null, episodeNumber: null };
      post(Object.assign({ type: 'title', movieId: String(msg.movieId) }, info));
    }
  });

  // V4/cache-grouping: show/episode/season metadata, used both for the
  // "生詞本" feature's `save-transcript` payload and (2026-07-06) for
  // grouping cache-management entries by series. Uses the same private
  // player API surface pollActiveTrack() above already relies on
  // (`netflix.appContext.state.playerApp.getAPI()`), just different methods
  // on it — verified against the real-world Subadub extension's
  // (github.com/rsimmons/subadub) SRT-download filename logic, which solves
  // the exact same problem the same way: `api.getVideoMetadataByVideoId(movieId)
  // .getCurrentVideo()`, then `.getTitle()`, `.isEpisodic()`,
  // `.getEpisodeTitle()`, `.getSeason()._season.seq`, `.getEpisodeNumber()`.
  // Notably, Subadub falls back straight to movieId — not `document.title`
  // — when this API is unavailable, which matches this project's own
  // experience: `document.title` isn't a reliable source of the show/
  // episode title during Netflix playback. Wrapped in try/catch per this
  // project's Netflix-interception rule (must never throw into the host
  // page); returns null on any failure, which content.js treats as "fall
  // back to document.title, then to the raw movieId."
  //
  // `getSeason()._season.seq` reaches into an internal (`_`-prefixed)
  // field, same as Subadub does — there's no known public accessor for the
  // season number. This is a *second, independent* best-effort layer beyond
  // the rest of this function (which is itself unverified against a live
  // Netflix page — see PLAN.md V4): if this specific piece breaks, the
  // surrounding try/catch means it only costs season-grouping, not the
  // series title or episode title.
  function getVideoTitle(movieId) {
    try {
      const playerApp = window.netflix && window.netflix.appContext &&
        window.netflix.appContext.state && window.netflix.appContext.state.playerApp;
      const api = playerApp && playerApp.getAPI && playerApp.getAPI();
      const videoMeta = api && typeof api.getVideoMetadataByVideoId === 'function' &&
        api.getVideoMetadataByVideoId(String(movieId));
      const current = videoMeta && typeof videoMeta.getCurrentVideo === 'function' && videoMeta.getCurrentVideo();
      if (!current || typeof current.getTitle !== 'function') return null;
      const seriesTitle = current.getTitle() || null;
      let episodeTitle = null;
      let seasonNumber = null;
      let episodeNumber = null;
      if (typeof current.isEpisodic === 'function' && current.isEpisodic()) {
        if (typeof current.getEpisodeTitle === 'function') {
          episodeTitle = current.getEpisodeTitle() || null;
        }
        try {
          const season = current.getSeason && current.getSeason();
          const seq = season && season._season && season._season.seq;
          if (typeof seq === 'number') seasonNumber = seq;
        } catch (e) { dbg('getVideoTitle: season lookup failed:', e && e.message); }
        if (typeof current.getEpisodeNumber === 'function') {
          const num = current.getEpisodeNumber();
          if (typeof num === 'number') episodeNumber = num;
        }
      }
      dbg('getVideoTitle:', movieId, '->', seriesTitle, episodeTitle, seasonNumber, episodeNumber);
      return { seriesTitle: seriesTitle, episodeTitle: episodeTitle,
               seasonNumber: seasonNumber, episodeNumber: episodeNumber };
    } catch (e) {
      dbg('getVideoTitle error (Netflix player API likely changed):', e && e.message);
      return null;
    }
  }

  async function fetchTrack(movieId, trackId, purpose) {
    const tracks = trackCache.get(movieId) || [];
    const track = tracks.find((t) => t.id === trackId);
    if (!track) {
      post({ type: 'track-error', movieId: movieId, trackId: trackId, purpose: purpose, error: 'track-not-found' });
      return;
    }
    try {
      const res = await fetch(track.url);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const text = await res.text();
      const cues = track.format === 'webvtt' ? parseWebVTT(text) : parseTTML(text);
      dbg('fetchTrack: format=', track.format, 'bytes=', text.length, 'cues=', cues.length, 'purpose=', purpose);
      post({ type: 'cues', movieId: movieId, trackId: trackId, purpose: purpose, cues: cues });
    } catch (e) {
      dbg('fetchTrack error:', e && e.message);
      post({ type: 'track-error', movieId: movieId, trackId: trackId, purpose: purpose, error: String(e && e.message || e) });
    }
  }

  // ---------------------------------------------------------------------------
  // Parsers
  // ---------------------------------------------------------------------------
  function clockTime(s) {
    // "HH:MM:SS.mmm" or "MM:SS.mmm"
    const parts = s.split(':');
    let h = 0, m, rest;
    if (parts.length === 3) { h = +parts[0]; m = +parts[1]; rest = parts[2]; }
    else { m = +parts[0]; rest = parts[1]; }
    const secParts = rest.split('.');
    return h * 3600 + m * 60 + (+secParts[0]) + (+(secParts[1] || 0)) / Math.pow(10, (secParts[1] || '').length || 1);
  }

  function decodeEntities(s) {
    return s
      .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
      .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n));
  }

  function stripTags(s) {
    return decodeEntities(s.replace(/<[^>]*>/g, ''));
  }

  function mergeCues(cues) {
    cues.sort((a, b) => a.start - b.start || a.end - b.end);
    const out = [];
    for (const c of cues) {
      const prev = out[out.length - 1];
      if (prev && Math.abs(prev.start - c.start) < 0.02 && Math.abs(prev.end - c.end) < 0.02) {
        if (prev.text !== c.text && !prev.text.includes(c.text)) prev.text += '\n' + c.text;
      } else {
        out.push({ start: c.start, end: c.end, text: c.text });
      }
    }
    return out;
  }

  function parseWebVTT(text) {
    const cues = [];
    const lines = text.replace(/\r/g, '').split('\n');
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(/^\s*([\d:.]+)\s+-->\s+([\d:.]+)/);
      if (!m) continue;
      const start = clockTime(m[1]);
      const end = clockTime(m[2]);
      const buf = [];
      for (i++; i < lines.length && lines[i].trim() !== ''; i++) buf.push(lines[i]);
      const cueText = stripTags(buf.join('\n')).trim();
      if (cueText) cues.push({ start: start, end: end, text: cueText });
    }
    return mergeCues(cues);
  }

  function parseTTML(text) {
    const doc = new DOMParser().parseFromString(text, 'text/xml');
    const tt = doc.documentElement;
    const tickRateAttr = tt.getAttribute('ttp:tickRate') ||
      tt.getAttributeNS('http://www.w3.org/ns/ttml#parameter', 'tickRate');
    const tickRate = +(tickRateAttr || 10000000);
    const parseTime = (v) => {
      if (!v) return 0;
      if (v.endsWith('t')) return parseInt(v, 10) / tickRate;
      if (v.endsWith('ms')) return parseFloat(v) / 1000;
      if (v.endsWith('s')) return parseFloat(v);
      return clockTime(v);
    };
    const cues = [];
    const paragraphs = doc.getElementsByTagName('p');
    for (let i = 0; i < paragraphs.length; i++) {
      const p = paragraphs[i];
      const start = parseTime(p.getAttribute('begin'));
      const end = parseTime(p.getAttribute('end'));
      let t = '';
      (function walk(node) {
        for (const child of node.childNodes) {
          if (child.nodeType === 3) t += child.textContent;
          else if (child.nodeName.toLowerCase() === 'br') t += '\n';
          else walk(child);
        }
      })(p);
      t = t.replace(/\s*\n\s*/g, '\n').trim();
      if (t) cues.push({ start: start, end: end, text: t });
    }
    return mergeCues(cues);
  }
})();
