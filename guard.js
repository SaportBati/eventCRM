/* Проверка «вы человек» (Cloudflare Turnstile).
   Воркер сам считает действия и отвечает 429 {error:"captcha_required"},
   когда их слишком много. guardedFetch ловит этот ответ, показывает проверку
   и после успеха автоматически повторяет исходный запрос. */
(function () {
  var WORKER_URL = "https://bitter-breeze-2c7b.vitadensikloh.workers.dev";
  // Публичный ключ виджета Turnstile. Тестовый ключ ниже всегда пропускает —
  // замените на свой из панели Cloudflare (Turnstile → Add widget).
  var SITE_KEY = "0x4AAAAAAFNw2v5BkvIQlJNK";

  var pending = null;
  var scriptPromise = null;

  function loadTurnstile() {
    if (window.turnstile) return Promise.resolve();
    if (scriptPromise) return scriptPromise;
    scriptPromise = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
      s.async = true;
      s.onload = function () { resolve(); };
      s.onerror = function () { scriptPromise = null; reject(new Error('turnstile_load_failed')); };
      document.head.appendChild(s);
    });
    return scriptPromise;
  }

  function injectStyles() {
    if (document.getElementById('humanCheckStyles')) return;
    var st = document.createElement('style');
    st.id = 'humanCheckStyles';
    st.textContent =
      '.hc-overlay{position:fixed;inset:0;z-index:4000;display:flex;align-items:center;justify-content:center;padding:20px;background:rgba(22,21,15,.72)}' +
      '.hc-card{width:100%;max-width:400px;background:var(--paper-2,#f5f2ea);color:var(--ink,#16150f);border:1px solid var(--ink,#16150f);box-shadow:8px 8px 0 var(--ink,#16150f);padding:26px}' +
      '.hc-card h3{font-family:var(--serif,Georgia,serif);font-size:24px;font-weight:700;line-height:1.1;margin-bottom:10px;padding-bottom:10px;border-bottom:2px solid var(--ink,#16150f)}' +
      '.hc-card p{font-size:13px;line-height:1.6;color:var(--ink-2,#4a463b);margin-bottom:16px}' +
      '.hc-widget{min-height:65px;display:flex;justify-content:center;margin-bottom:12px}' +
      '.hc-err{min-height:18px;font-size:12.5px;color:var(--red,#c8381f);margin-bottom:10px}' +
      '.hc-actions{display:flex;justify-content:flex-end}';
    document.head.appendChild(st);
  }

  function askHuman(hwid) {
    if (pending) return pending;
    pending = new Promise(function (resolve) {
      injectStyles();
      var overlay = document.createElement('div');
      overlay.className = 'hc-overlay';
      overlay.innerHTML =
        '<div class="hc-card" role="dialog" aria-modal="true" aria-labelledby="hcTitle">' +
        '<h3 id="hcTitle">Проверка безопасности</h3>' +
        '<p>Слишком много действий подряд. Подтвердите, что вы человек, и мы продолжим.</p>' +
        '<div class="hc-widget" id="hcWidget"></div>' +
        '<div class="hc-err" id="hcErr"></div>' +
        '<div class="hc-actions"><button type="button" class="btn ghost" id="hcCancel">Отмена</button></div>' +
        '</div>';
      document.body.appendChild(overlay);

      var widgetId = null;
      function finish(result) {
        try { if (widgetId !== null && window.turnstile) window.turnstile.remove(widgetId); } catch (e) { }
        overlay.remove();
        pending = null;
        resolve(result);
      }
      function setErr(t) { var el = overlay.querySelector('#hcErr'); if (el) el.textContent = t || ''; }

      overlay.querySelector('#hcCancel').addEventListener('click', function () { finish(false); });

      loadTurnstile().then(function () {
        widgetId = window.turnstile.render('#hcWidget', {
          sitekey: SITE_KEY,
          theme: 'auto',
          callback: function (token) {
            setErr('');
            fetch(WORKER_URL + '/verify-human', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'X-HWID': hwid || '' },
              body: JSON.stringify({ token: token })
            }).then(function (r) { return r.json().catch(function () { return null; }); })
              .then(function (d) {
                if (d && d.ok) { finish(true); return; }
                setErr('Проверка не пройдена' + (d && d.error ? ' (' + d.error + (d.codes && d.codes.length ? ': ' + d.codes.join(', ') : '') + ')' : '') + '. Попробуйте ещё раз.');
                try { window.turnstile.reset(widgetId); } catch (e) { }
              })
              .catch(function () {
                setErr('Не удалось связаться с сервером.');
                try { window.turnstile.reset(widgetId); } catch (e) { }
              });
          },
          'error-callback': function () { setErr('Не удалось загрузить проверку. Обновите страницу.'); },
          'expired-callback': function () { try { window.turnstile.reset(widgetId); } catch (e) { } }
        });
      }).catch(function () {
        setErr('Не удалось загрузить проверку Cloudflare. Проверьте соединение.');
      });
    });
    return pending;
  }

  window.guardedFetch = async function (url, opts) {
    var resp = await fetch(url, opts);
    if (resp.status !== 429) return resp;
    var d = null;
    try { d = await resp.clone().json(); } catch (e) { }
    if (!d || d.error !== 'captcha_required') return resp;

    var hwid = (opts && opts.headers && opts.headers['X-HWID']) || '';
    if (!hwid) { try { hwid = localStorage.getItem('authorized_hwid') || ''; } catch (e) { } }
    var ok = await askHuman(hwid);
    if (!ok) return resp;
    return fetch(url, opts); // повторяем исходный запрос
  };
})();
