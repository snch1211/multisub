// Runs in the page's main world. Declared as a `world: "MAIN"` content script
// at document_start so the hooks below are in place before Netflix's player
// boots; content.js also injects it with a <script> tag as a fallback, and the
// page-world flag below keeps the two from both running.
//
// Responsibilities:
//  1. Hook JSON.stringify so Netflix's manifest request also asks for the
//     WebVTT subtitle profile (much easier to parse than TTML).
//  2. Hook JSON.parse and Response.prototype.json to capture the manifest
//     response, which lists every timed-text track (with download URLs) for
//     the episode. Netflix has used both paths over time.
//  3. Report the subtitle and audio tracks selected in Netflix's player.
//  4. On request from the content script, fetch a track, parse it into cues
//     [{start, end, text}], and post them back via window.postMessage.
//
// The messages between this file and content.js are a protocol between
// versions. Only the first copy of this file runs in a page (the
// __multisubInjected guard below), and the page world outlives the
// extension: after Safari reloads the extension (an update, or turning it
// off and on) the new content.js is injected into open tabs and talks to the
// inject.js the page loaded with, possibly from an older version, until the
// tab is reloaded. So:
//  - never rename or remove a message type or field, or change what one
//    means; posts are { __multisub: true, type, ... }, commands are
//    { __multisub_cmd: true, type, ... };
//  - anything new is optional: content.js must work with an inject.js that
//    doesn't send it, and inject.js ignores commands and fields it doesn't
//    know;
//  - a change to what this file computes (how it parses a track, say) only
//    reaches pages loaded after the update, so content.js must not depend on
//    it either.
(() => {
  'use strict';
  // An engine that ignores `world: "MAIN"` would run this in the isolated
  // world, where hooking JSON/fetch does nothing for the page and the flag
  // below would land on the wrong window, blocking nothing. Bail out there and
  // let content.js's <script> injection do the job.
  try {
    if (typeof browser !== 'undefined' && browser.runtime && browser.runtime.id) return;
    if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.id) return;
  } catch (e) { /* page world: no extension APIs, carry on */ }
  if (window.__multisubInjected) return;
  window.__multisubInjected = true;

  const WEBVTT_PROFILE = 'webvtt-lssdh-ios8';

  const DEBUG = false;
  function dbg() {
    if (!DEBUG) return;
    try { console.log.apply(console, ['[MultiSub][inject]'].concat([].slice.call(arguments))); } catch (e) { /* ignore */ }
  }
  dbg('page-world script loaded at', location.pathname);

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
  // Capture manifest responses (movieId + text tracks). Netflix has parsed
  // them with JSON.parse at some times and with Response.json() at others, so
  // both are hooked. Neither hook may ever change what the page gets back.
  // ---------------------------------------------------------------------------
  const origParse = JSON.parse;
  JSON.parse = function () {
    const value = origParse.apply(this, arguments);
    try { scanForManifest(value); } catch (e) { /* never break the page */ }
    return value;
  };

  try {
    const origJson = Response.prototype.json;
    if (typeof origJson === 'function') {
      Response.prototype.json = function () {
        const promise = origJson.apply(this, arguments);
        try {
          // Observe on a side branch so the page keeps the very same promise
          // (same resolution, same rejection) it would have had without us.
          promise.then((value) => {
            try { scanForManifest(value); } catch (e) { /* ignore */ }
          }, () => {});
        } catch (e) { /* ignore */ }
        return promise;
      };
    }
  } catch (e) { dbg('Response.json hook not installed:', e && e.message); }

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

  // Public (URL-free) view of a track list, as content.js sees it.
  function publicTracks(tracks) {
    return tracks.map((t) => ({
      id: t.id, language: t.language, label: t.label,
      forced: t.forced, trackType: t.trackType, format: t.format
    }));
  }

  // movieId -> signature of the last track list posted, so the same manifest
  // seen through both hooks (or re-fetched by the player) doesn't make
  // content.js re-run its track selection.
  const lastPostedTracks = new Map();

  function handleManifest(manifest) {
    const list = Array.isArray(manifest.textTracks) ? manifest.textTracks
               : (manifest.timedtexttracks || []);
    const tracks = [];
    for (const t of list) {
      if (!t || t.isNoneTrack || t.isNone) continue;
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
    dbg('handleManifest: movieId=', manifest.movieId, 'usable tracks=', tracks.length);
    if (!tracks.length) return;
    const movieId = String(manifest.movieId);
    // Always keep the newest URLs (they expire), but only tell content.js
    // when the list itself changed.
    trackCache.set(movieId, tracks);
    const sig = tracks.map((t) => t.id + '|' + t.format).join(',');
    if (lastPostedTracks.get(movieId) === sig) return;
    lastPostedTracks.set(movieId, sig);
    // Don't leak URLs to the content script; it asks back by trackId.
    post({ type: 'tracks', movieId: movieId, tracks: publicTracks(tracks) });
  }

  // ---------------------------------------------------------------------------
  // Selected tracks in Netflix's player, so content.js can follow the
  // subtitle the viewer picked and knows the audio language. This is the
  // undocumented private player API: every access sits inside the try/catch
  // below, and any failure only stops these reports (content.js then falls
  // back to its own track choice).
  // ---------------------------------------------------------------------------
  const lastActiveTrackSig = new Map(); // movieId -> "subtitle|name|forced|audio" signature

  function getPlayerApi() {
    const playerApp = window.netflix && window.netflix.appContext &&
      window.netflix.appContext.state && window.netflix.appContext.state.playerApp;
    return playerApp && playerApp.getAPI && playerApp.getAPI();
  }

  function audioLanguageOf(player) {
    try {
      const audio = typeof player.getAudioTrack === 'function' ? player.getAudioTrack() : null;
      if (!audio) return null;
      return audio.bcp47 || audio.bcp47Code || audio.language || null;
    } catch (e) {
      return null;
    }
  }

  function pollActiveTrack() {
    try {
      const api = getPlayerApi();
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
        // With subtitles "off", Netflix may still show a forced-narrative
        // track (signs, foreign-language bits); content.js must not take that
        // for the full subtitle being on screen.
        let forced = false;
        if (track && !track.isNoneTrack) {
          bcp47 = track.bcp47Code || track.bcp47 || track.language || null;
          displayName = track.displayName || track.trackDisplayName || null;
          forced = !!(track.isForcedNarrative || track.isForced);
        }
        const audioBcp47 = audioLanguageOf(player);
        const movieIdStr = String(movieId);
        const sig = bcp47 + '|' + displayName + '|' + forced + '|' + audioBcp47;
        if (lastActiveTrackSig.get(movieIdStr) === sig) continue;
        lastActiveTrackSig.set(movieIdStr, sig);
        dbg('active-track changed:', movieIdStr, bcp47, displayName, 'audio=', audioBcp47);
        post({ type: 'active-track', movieId: movieIdStr, bcp47: bcp47, displayName: displayName, forced: forced, audioBcp47: audioBcp47 });
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
      const movieId = String(msg.movieId);
      // content.js asks after every navigation and has forgotten what it was
      // told before, so report the selected tracks again on the next poll.
      lastActiveTrackSig.delete(movieId);
      const tracks = trackCache.get(movieId);
      if (tracks) post({ type: 'tracks', movieId: movieId, tracks: publicTracks(tracks) });
    } else if (msg.type === 'get-title') {
      const info = getVideoTitle(msg.movieId) ||
        { seriesTitle: null, episodeTitle: null, seasonNumber: null, episodeNumber: null };
      post(Object.assign({ type: 'title', movieId: String(msg.movieId) }, info));
    }
  });

  // Show/episode/season metadata, used for the vocabulary feature's
  // `save-transcript` payload and for grouping cache entries by series in the
  // app. Same private player API surface as pollActiveTrack(), different
  // methods on it. The approach follows the Subadub extension
  // (github.com/rsimmons/subadub), which names its SRT downloads the same way:
  // `api.getVideoMetadataByVideoId(movieId).getCurrentVideo()`, then
  // `.getTitle()`, `.isEpisodic()`, `.getEpisodeTitle()`,
  // `.getSeason()._season.seq`, `.getEpisodeNumber()`. Like Subadub, content.js
  // falls back to the movieId rather than `document.title`, which isn't a
  // reliable source of the title during playback. Returns null on any failure
  // and never throws into the page.
  //
  // `getSeason()._season.seq` reaches into an internal (`_`-prefixed) field,
  // as Subadub does; there's no known public accessor for the season number.
  // It has its own try/catch so that if it breaks, only season grouping is
  // lost, not the series or episode title.
  function getVideoTitle(movieId) {
    try {
      const api = getPlayerApi();
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
      dbg('fetchTrack:', track.format, text.length, 'bytes,', cues.length, 'cues, purpose=', purpose);
      // `cleaned`: every cue's text went through cleanText(). content.js
      // cleans cues from an inject.js that doesn't say so (one from before
      // this field, whose TTML parser left direction marks in).
      post({ type: 'cues', movieId: movieId, trackId: trackId, purpose: purpose, cues: cues, cleaned: true });
    } catch (e) {
      dbg('fetchTrack error:', e && e.message);
      // The URL may have expired. Forget what was posted, so the next
      // manifest Netflix fetches (with fresh URLs) reaches content.js even
      // though the track list itself is the same, and it can try again.
      if (purpose === 'source') lastPostedTracks.delete(movieId);
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

  // Netflix's subtitle files use named entities beyond the basic five,
  // notably &lrm;/&rlm; (left-to-right / right-to-left marks) in front of
  // most lines, which used to show up literally as "&lrm;". A <textarea>
  // decodes every named and numeric entity without parsing any markup.
  const entityDecoder = document.createElement('textarea');
  const BIDI_CONTROLS = /[\u200E\u200F\u202A-\u202E\u2066-\u2069]/g;
  // Netflix's files sometimes encode the mark twice ("&amp;lrm;"), so decode
  // up to two rounds, then drop any direction-mark entity still left as text.
  const LITERAL_MARKS = /&(?:lrm|rlm|#x200[ef]|#820[67]);/gi;
  function decodeEntities(s) {
    let out = s;
    for (let round = 0; round < 2 && out.indexOf('&') !== -1; round++) {
      // Entity names are case-sensitive in HTML, but "&LRM;" also appears.
      out = out.replace(/&(lrm|rlm);/gi, (_, m) => '&' + m.toLowerCase() + ';');
      entityDecoder.innerHTML = out;
      out = entityDecoder.value;
    }
    return out;
  }

  // What both parsers do to a cue's text once its markup is gone, so a cue
  // reads the same whether Netflix served WebVTT or TTML: entities decoded
  // (in TTML the XML parser has decoded one level already, which turns
  // Netflix's "&amp;lrm;" into the text "&lrm;"), then the direction marks
  // and other invisible bidi controls removed, whether they came as
  // characters (TTML's "&#8206;") or as entities left as text: the overlay
  // sets its own direction, and the AI prompts must not get them in their
  // reference lines. Non-breaking spaces become plain ones, and each line
  // is trimmed.
  function cleanText(s) {
    return decodeEntities(s).replace(LITERAL_MARKS, '').replace(BIDI_CONTROLS, '').replace(/\u00A0/g, ' ')
      .replace(/[ \t]*\n[ \t]*/g, '\n').trim();
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
      const cueText = cleanText(buf.join('\n').replace(/<[^>]*>/g, ''));
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
      t = cleanText(t.replace(/\s*\n\s*/g, '\n'));
      if (t) cues.push({ start: start, end: end, text: t });
    }
    return mergeCues(cues);
  }
})();
