(() => {
  'use strict';

  if (window.__KANCOLLE_IOS_BRIDGE__) return;
  window.__KANCOLLE_IOS_BRIDGE__ = true;

  const post = (message) => {
    try {
      window.webkit?.messageHandlers?.kcsBridge?.postMessage(message);
    } catch (_) {}
  };

  post({ type: 'bridge', href: location.href });

  const parse = (text) => {
    if (typeof text !== 'string' || !text.length) return null;
    try {
      return JSON.parse(text.trim().replace(/^svdata=/, ''));
    } catch (_) {
      return null;
    }
  };

  const pathOf = (url) => {
    try { return new URL(url, location.href).pathname; }
    catch (_) { return String(url || '').split('?')[0]; }
  };

  const requestParams = (body) => {
    const out = {};
    if (typeof body !== 'string') return out;
    try {
      const params = new URLSearchParams(body);
      for (const [key, value] of params.entries()) out[key] = value;
    } catch (_) {}
    return out;
  };

  const projectShip = (ship) => ({
    instanceId: ship?.api_id ?? 0,
    masterId: ship?.api_ship_id ?? 0,
    level: ship?.api_lv ?? 0,
    nowHP: ship?.api_nowhp ?? 0,
    maxHP: ship?.api_maxhp ?? 1,
    fuel: ship?.api_fuel ?? 0,
    ammo: ship?.api_bull ?? 0,
    onslot: Array.isArray(ship?.api_onslot) ? ship.api_onslot : []
  });

  const projectDeck = (deck) => ({
    id: deck?.api_id ?? 0,
    ships: Array.isArray(deck?.api_ship) ? deck.api_ship : []
  });

  const projectShell = (phase) => {
    if (!phase) return null;
    return {
      dfList: Array.isArray(phase.api_df_list) ? phase.api_df_list : [],
      damage: Array.isArray(phase.api_damage) ? phase.api_damage : [],
      atEflag: Array.isArray(phase.api_at_eflag) ? phase.api_at_eflag : []
    };
  };

  const projectBattle = (data) => ({
    fNowHPs: data?.api_f_nowhps ?? [],
    fMaxHPs: data?.api_f_maxhps ?? [],
    fNowHPsCombined: data?.api_f_nowhps_combined ?? [],
    fMaxHPsCombined: data?.api_f_maxhps_combined ?? [],
    airFDam: data?.api_kouku?.api_stage3?.api_fdam ?? [],
    airCombinedFDam: data?.api_kouku?.api_stage3_combined?.api_fdam ?? [],
    combinedAirFDam: data?.api_kouku_combined?.api_stage3?.api_fdam ?? [],
    openingFDam: data?.api_opening_atack?.api_fdam ?? [],
    openingTaisen: projectShell(data?.api_opening_taisen),
    hougeki1: projectShell(data?.api_hougeki1),
    hougeki2: projectShell(data?.api_hougeki2),
    hougeki3: projectShell(data?.api_hougeki3),
    hougeki: projectShell(data?.api_hougeki),
    nightHougeki1: projectShell(data?.api_n_hougeki1),
    nightHougeki2: projectShell(data?.api_n_hougeki2),
    raigekiFDam: data?.api_raigeki?.api_fdam ?? [],
    raigekiCombinedFDam: data?.api_raigeki_combined?.api_fdam ?? []
  });

  const projectData = (path, data) => {
    if (path.includes('/api_start2/getData')) {
      return {
        masterShips: (data?.api_mst_ship ?? []).map((ship) => ({
          id: ship?.api_id ?? 0,
          name: ship?.api_name ?? ''
        }))
      };
    }

    if (path.includes('/api_port/port')) {
      return {
        ships: (data?.api_ship ?? []).map(projectShip),
        decks: (data?.api_deck_port ?? []).map(projectDeck),
        combinedFlag: data?.api_combined_flag ?? 0
      };
    }

    if (path.includes('/api_get_member/ship_deck') ||
        path.includes('/api_get_member/ship2') ||
        path.includes('/api_get_member/ship3')) {
      const ships = Array.isArray(data)
        ? data
        : (data?.api_ship_data ?? data?.api_ship ?? []);
      const decks = data?.api_deck_data ?? data?.api_deck_port ?? [];
      return {
        ships: Array.isArray(ships) ? ships.map(projectShip) : [],
        decks: Array.isArray(decks) ? decks.map(projectDeck) : []
      };
    }

    if (path.includes('/api_get_member/deck')) {
      const decks = Array.isArray(data) ? data : (data?.api_deck_data ?? []);
      return { decks: Array.isArray(decks) ? decks.map(projectDeck) : [] };
    }

    if (/\/api_req_(sortie|combined_battle|battle_midnight)\//.test(path) &&
        !path.includes('/battleresult') &&
        !path.includes('/goback_port')) {
      return { battle: projectBattle(data) };
    }

    return {};
  };

  const isInteresting = (path) => (
    path.includes('/api_start2/getData') ||
    path.includes('/api_port/port') ||
    path.includes('/api_get_member/ship_deck') ||
    path.includes('/api_get_member/ship2') ||
    path.includes('/api_get_member/ship3') ||
    path.includes('/api_get_member/deck') ||
    path.includes('/api_req_map/start') ||
    path.includes('/api_req_map/next') ||
    path.includes('/battleresult') ||
    path.includes('/goback_port') ||
    /\/api_req_(sortie|combined_battle|battle_midnight)\//.test(path)
  );

  const emit = (url, body, text) => {
    const rawURL = String(url || '');
    if (!rawURL.includes('/kcsapi/')) return;

    const path = pathOf(rawURL);
    if (!isInteresting(path)) return;

    const parsed = parse(text);
    if (!parsed || parsed.api_result !== 1) return;

    post({
      type: 'api',
      path,
      request: requestParams(body),
      data: projectData(path, parsed.api_data)
    });
  };

  try {
    const originalOpen = XMLHttpRequest.prototype.open;
    const originalSend = XMLHttpRequest.prototype.send;

    XMLHttpRequest.prototype.open = function(method, url, ...rest) {
      this.__kancolleIOSMeta = { method, url };
      return originalOpen.call(this, method, url, ...rest);
    };

    XMLHttpRequest.prototype.send = function(body) {
      const meta = this.__kancolleIOSMeta || {};
      this.addEventListener('load', () => {
        try {
          let text = '';
          if (!this.responseType || this.responseType === 'text') text = this.responseText || '';
          else if (this.responseType === 'json') text = JSON.stringify(this.response || {});
          emit(meta.url, body, text);
        } catch (_) {}
      }, { once: true });
      return originalSend.call(this, body);
    };
  } catch (_) {}

  try {
    if (window.fetch) {
      const originalFetch = window.fetch;
      window.fetch = async function(input, init = {}) {
        const response = await originalFetch.apply(this, arguments);
        try {
          const url = typeof input === 'string' ? input : input?.url;
          if (String(url || '').includes('/kcsapi/')) {
            response.clone().text().then((text) => emit(url, init.body || '', text)).catch(() => {});
          }
        } catch (_) {}
        return response;
      };
    }
  } catch (_) {}

  const reportGameRect = () => {
    if (window.top !== window.self || innerWidth <= 0 || innerHeight <= 0) return;

    const candidates = [...document.querySelectorAll('iframe, canvas')]
      .map((element) => ({ element, rect: element.getBoundingClientRect() }))
      .filter(({ rect }) => rect.width > 300 && rect.height > 180 && rect.bottom > 0 && rect.right > 0);

    if (!candidates.length) return;

    const targetAspect = 1200 / 720;
    candidates.sort((a, b) => {
      const score = ({ rect }) => {
        const aspect = rect.width / rect.height;
        return (rect.width * rect.height) / (1 + Math.abs(aspect - targetAspect) * 4);
      };
      return score(b) - score(a);
    });

    const rect = candidates[0].rect;
    post({
      type: 'gameRect',
      rect: {
        x: rect.left / innerWidth,
        y: rect.top / innerHeight,
        width: rect.width / innerWidth,
        height: rect.height / innerHeight
      }
    });
  };

  if (window.top === window.self) {
    addEventListener('resize', reportGameRect, { passive: true });
    addEventListener('scroll', reportGameRect, { passive: true });
    setTimeout(reportGameRect, 500);
    setTimeout(reportGameRect, 1500);
    setInterval(reportGameRect, 5000);
  }
})();
