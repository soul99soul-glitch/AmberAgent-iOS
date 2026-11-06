(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const controls = ['previous', 'toggle', 'next'].map($);
  let state = null;
  let tracks = [];
  let working = false;
  let timer = null;
  let pollingStopped = false;

  function showMessage(message, needsHelp = true) {
    $('message-text').textContent = message || '';
    $('setup-details').textContent = message ? `${message}\n请确认 ncm-cli 和 mpv 已安装，并在终端完成 ncm-cli configure 和 ncm-cli login。` : '';
    $('setup-help').hidden = !needsHelp;
    $('message').hidden = !message;
  }

  function showSearch(show, showDetails = false) {
    const root = document.documentElement;
    const opening = show && root.dataset.musicView !== 'search' && root.dataset.amberPresentation === 'expanded';
    const trigger = opening ? $('open-search').getBoundingClientRect() : null;
    const reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    document.documentElement.dataset.musicView = show ? 'search' : 'player';
    $('setup-details').hidden = !showDetails;
    $('retry-setup').hidden = !showDetails;
    if (show && !showDetails) {
      const input = $('query');
      if (opening && !reduced && typeof input.animate === 'function') {
        input.getAnimations().forEach(animation => animation.cancel());
        const target = input.getBoundingClientRect();
        if (target.width && target.height && trigger.width && trigger.height) {
          input.animate([
            { transformOrigin: 'top right', transform: `translate(${trigger.right - target.right}px, ${trigger.top - target.top}px) scaleX(${Math.max(.2, trigger.width / target.width)})`, opacity: .3 },
            { transformOrigin: 'top right', transform: 'none', opacity: 1 }
          ], { duration: 240, easing: 'ease-in-out' });
        }
      }
      input.focus();
    }
  }

  async function call(action, value) {
    if (!window.amber || !window.amber.neteaseMusic) throw new Error('当前 Amber 版本尚未接入网易云播放器。');
    const result = await window.amber.neteaseMusic.call(action, value);
    if (!result || typeof result !== 'object') throw new Error('网易云音乐返回的数据无法识别。');
    if (result.success === false || result.code && ![0, 200, '0', '200'].includes(result.code)) {
      throw new Error(String(result.message || result.msg || '网易云音乐操作失败，请检查登录、网络和播放权限。').slice(0, 300));
    }
    return result;
  }

  function text(value) { return typeof value === 'string' ? value : ''; }
  function nameList(value) {
    if (typeof value === 'string') return value;
    if (Array.isArray(value)) return value.map(item => typeof item === 'string' ? item : text(item && (item.name || item.artistName))).filter(Boolean).join(' / ');
    return value && text(value.name);
  }
  function trackInfo(item) {
    if (!item || typeof item !== 'object') return null;
    const encryptedId = String(item.encryptedId || item.encrypted_id || item.songId || item.id || '');
    const originalId = String(item.originalId || item.original_id || item.songOriginalId || '');
    if (!/^[a-f0-9]{32}$/i.test(encryptedId) || !/^\d{1,20}$/.test(originalId)) return null;
    const album = item.album || item.al || {};
    return {
      encryptedId, originalId,
      name: text(item.name || item.songName || item.title) || '未命名歌曲',
      artist: nameList(item.artists || item.artist || item.ar || item.singer || item.artistName) || '未知歌手',
      cover: text(item.coverUrl || item.picUrl || item.cover || album.picUrl || album.coverUrl),
      unavailable: item.visible === false || item.plLevel === 'none' || item.playable === false
    };
  }
  function collectTracks(value, found, depth = 0) {
    if (!value || typeof value !== 'object' || depth > 8 || found.length >= 50) return;
    if (Array.isArray(value)) { value.forEach(item => collectTracks(item, found, depth + 1)); return; }
    const track = trackInfo(value);
    if (track && !found.some(item => item.encryptedId === track.encryptedId)) found.push(track);
    Object.values(value).forEach(item => collectTracks(item, found, depth + 1));
  }
  function safeCover(raw) {
    try {
      const url = new URL(raw);
      if (!['http:', 'https:'].includes(url.protocol)) return '';
      const host = url.hostname.toLowerCase();
      if (!['music.126.net', 'music.163.com'].some(domain => host === domain || host.endsWith('.' + domain))) return '';
      url.protocol = 'https:';
      return url.href;
    } catch { return ''; }
  }
  function time(value) {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return '--:--';
    const seconds = Math.floor(value);
    return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
  }
  function setBusy(value) {
    working = value;
    controls.forEach(button => { button.disabled = value || !state; });
    document.querySelectorAll('#results button, #search-form button').forEach(button => { button.disabled = value || button.dataset.unavailable === 'true'; });
  }
  function renderState(payload) {
    const actual = payload.state || payload.data && payload.data.state;
    if (!actual || typeof actual !== 'object') throw new Error('播放器未返回可识别的播放状态。');
    state = actual;
    const status = String(actual.status || '').toLowerCase();
    const statusText = {playing: '正在播放', paused: '已暂停', stopped: '未播放', loading: '正在加载'}[status] || '播放状态未知';
    $('play-status').textContent = statusText;
    const playing = status === 'playing';
    $('play-icon').hidden = playing;
    $('pause-icon').hidden = !playing;
    $('toggle').setAttribute('aria-label', playing ? '暂停' : '播放');
    $('toggle').title = playing ? '暂停' : '播放';
    const current = actual.currentSong || actual.currentTrack || actual.track || actual.song || null;
    const id = String(actual.encryptedId || actual.songId || current && (current.encryptedId || current.id) || '');
    const details = current && typeof current === 'object' ? current : actual;
    const currentName = text(details.name || details.songName || details.title);
    const album = details.album || details.al || {};
    const item = trackInfo(current) || tracks.find(track => track.encryptedId === id) || (currentName ? {
      name: currentName,
      artist: nameList(details.artists || details.artist || details.ar || details.singer || details.artistName) || '未知歌手',
      cover: text(details.coverUrl || details.picUrl || album.picUrl || album.coverUrl)
    } : null);
    const noTrack = status === 'stopped';
    $('song-name').textContent = item ? item.name : noTrack ? '选择一首歌' : '播放器未提供歌曲信息';
    $('artist').textContent = item ? item.artist : noTrack ? '搜索后开始播放' : '可在网易云 CLI 中查看详情';
    $('mini-detail').textContent = item && playing ? item.artist : statusText;
    const cover = safeCover(item && item.cover || '');
    $('cover-image').hidden = !cover;
    if (cover) $('cover-image').src = cover; else $('cover-image').removeAttribute('src');
    const position = typeof actual.position === 'number' && Number.isFinite(actual.position) && actual.position >= 0 ? actual.position : null;
    const duration = typeof actual.duration === 'number' && Number.isFinite(actual.duration) && actual.duration > 0 ? actual.duration : null;
    $('position').textContent = time(position);
    $('duration').textContent = time(duration);
    const progress = duration > 0 && position != null ? Math.max(0, Math.min(100, position / duration * 100)) : 0;
    $('progress-fill').style.width = `${progress}%`;
    $('progress').toggleAttribute('data-live', playing && duration != null && position != null);
    if (duration > 0 && position != null) {
      $('progress').setAttribute('role', 'progressbar');
      $('progress').setAttribute('aria-valuenow', String(Math.round(progress)));
    } else {
      $('progress').removeAttribute('role');
      $('progress').removeAttribute('aria-valuenow');
      $('progress').removeAttribute('data-live');
    }
    setBusy(working);
  }
  async function refresh() {
    if (working) return;
    try { renderState(await call('state')); }
    catch (error) {
      state = null;
      $('play-status').textContent = '播放器不可用';
      $('song-name').textContent = '选择一首歌';
      $('artist').textContent = '搜索后开始播放';
      $('mini-detail').textContent = '播放器不可用';
      $('cover-image').hidden = true;
      $('cover-image').removeAttribute('src');
      $('position').textContent = $('duration').textContent = '--:--';
      $('progress-fill').style.width = '0';
      $('progress').removeAttribute('role');
      $('progress').removeAttribute('aria-valuenow');
      $('progress').removeAttribute('data-live');
      setBusy(false); pollingStopped = true; showMessage(error.message);
    }
  }
  async function loop() {
    clearTimeout(timer);
    if (document.visibilityState === 'visible' && !pollingStopped) await refresh();
    if (!pollingStopped) timer = setTimeout(loop, 3000);
  }
  async function perform(action, value) {
    if (working) return;
    setBusy(true);
    try {
      await call(action, value);
      showMessage(action === 'enqueue' ? '已加入播放队列。' : '', false);
      renderState(await call('state'));
      if (action === 'play') showSearch(false);
      pollingStopped = false;
    } catch (error) { showMessage(error.message); }
    finally { setBusy(false); if (!pollingStopped) loop(); }
  }
  function renderResults() {
    const list = $('results'); list.replaceChildren();
    $('empty').hidden = tracks.length > 0;
    $('result-count').textContent = tracks.length ? `${tracks.length} 首` : '';
    for (const track of tracks) {
      const row = document.createElement('li'); row.className = 'result';
      const info = document.createElement('div'); info.className = 'result-info';
      const title = document.createElement('strong'); title.textContent = track.name;
      const detail = document.createElement('span'); detail.textContent = track.artist + (track.unavailable ? ' · 暂无播放权限' : '');
      info.append(title, detail); row.append(info);
      for (const [label, action] of [['播放', 'play'], ['加入队列', 'enqueue']]) {
        const button = document.createElement('button'); button.type = 'button'; button.textContent = label;
        button.disabled = track.unavailable; button.dataset.unavailable = String(track.unavailable);
        button.setAttribute('aria-label', `${label} ${track.name}`);
        button.addEventListener('click', () => perform(action, {encryptedId: track.encryptedId, originalId: track.originalId}));
        row.append(button);
      }
      list.append(row);
    }
  }
  $('search-form').addEventListener('submit', async event => {
    event.preventDefault();
    const keyword = $('query').value.trim();
    if (!keyword || working) return;
    setBusy(true); showMessage('');
    try {
      const result = await call('search', keyword);
      const found = []; collectTracks(result, found); tracks = found; renderResults();
      $('empty').textContent = '未找到可识别的歌曲结果。';
    } catch (error) { showMessage(error.message); }
    finally { setBusy(false); }
  });
  $('previous').addEventListener('click', () => perform('prev'));
  $('next').addEventListener('click', () => perform('next'));
  $('toggle').addEventListener('click', () => perform(state && state.status === 'playing' ? 'pause' : 'resume'));
  $('refresh').addEventListener('click', () => { pollingStopped = false; showMessage(''); loop(); });
  $('retry-setup').addEventListener('click', () => { pollingStopped = false; showMessage(''); showSearch(false); loop(); });
  $('open-search').addEventListener('click', () => showSearch(true));
  $('back-to-player').addEventListener('click', () => showSearch(false));
  $('setup-help').addEventListener('click', () => showSearch(true, true));
  $('cover-image').addEventListener('error', () => { $('cover-image').hidden = true; });
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && !pollingStopped) loop(); });
  setBusy(false);
  loop();
})();
