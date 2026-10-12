/* Motion — единая точка анимаций сайта (anime.js v3).
   Принципы: короткие (150–600 мс), только opacity/transform, небольшие смещения,
   без бесконечных циклов. При prefers-reduced-motion и при недоступном anime.js
   всё просто показывается сразу — страницы работают и без анимаций. */
(function () {
  'use strict';

  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var ok = typeof window.anime === 'function' && !reduce;

  function list(t) {
    if (!t) return [];
    if (typeof t === 'string') return [].slice.call(document.querySelectorAll(t));
    if (t.nodeType === 1) return [t];
    return [].slice.call(t);
  }
  function clear(nodes) {
    nodes.forEach(function (n) { n.style.opacity = ''; n.style.transform = ''; });
  }

  /* Появление группы элементов: fade + лёгкий подъём, со ступенчатой задержкой.
     Общая длительность каскада ограничена, чтобы длинные списки не «тянулись». */
  function reveal(target, o) {
    var n = list(target);
    if (!n.length || !ok) return;
    o = o || {};
    var y = Math.min(o.y == null ? 10 : o.y, 14);
    var step = Math.min(o.stagger == null ? 40 : o.stagger, 450 / Math.max(1, n.length - 1));
    n.forEach(function (e) { e.style.opacity = 0; });
    anime({
      targets: n, opacity: [0, 1], translateY: [y, 0],
      duration: Math.min(o.duration || 450, 600),
      delay: anime.stagger(step, { start: o.delay || 0 }),
      easing: 'easeOutCubic',
      complete: function () { clear(n); }
    });
  }

  /* Всплытие одного элемента: модалки, лайтбокс, миниатюры, раскрытая строка */
  function pop(target, o) {
    var n = list(target);
    if (!n.length || !ok) return;
    o = o || {};
    n.forEach(function (e) { e.style.opacity = 0; });
    anime({
      targets: n, opacity: [0, 1],
      translateY: [o.y == null ? 6 : o.y, 0],
      scale: [o.scale || 0.97, 1],
      duration: o.duration || 200, easing: 'easeOutQuad',
      complete: function () { clear(n); }
    });
  }

  function fadeIn(target) {
    var n = list(target);
    if (!n.length || !ok) return;
    n.forEach(function (e) { e.style.opacity = 0; });
    anime({
      targets: n, opacity: [0, 1], translateY: [-4, 0],
      duration: 220, easing: 'easeOutQuad', complete: function () { clear(n); }
    });
  }

  /* Короткий «пульс» — подтверждение действия (например, слот сохранён) */
  function pulse(target) {
    var n = list(target);
    if (!n.length || !ok) return;
    anime({
      targets: n, scale: [1, 1.04, 1], duration: 420,
      easing: 'easeInOutQuad', complete: function () { clear(n); }
    });
  }

  /* Рост столбиков снизу вверх */
  function grow(target) {
    var n = list(target);
    if (!n.length || !ok) return;
    anime({
      targets: n, scaleY: [0, 1], duration: 500,
      delay: anime.stagger(25), easing: 'easeOutCubic',
      complete: function () { clear(n); }
    });
  }

  /* Счётчик: от 0 до значения */
  function countUp(el, target, o) {
    if (!el) return;
    o = o || {};
    var fmt = o.format || (o.decimals
      ? function (v) { return Number(v).toFixed(o.decimals); }
      : function (v) { return Math.round(v).toLocaleString('ru-RU'); });
    target = Number(target) || 0;
    if (!ok) { el.textContent = fmt(target); return; }
    var obj = { v: 0 };
    anime({
      targets: obj, v: target, duration: o.duration || 900, delay: o.delay || 0,
      easing: 'easeOutExpo',
      update: function () { el.textContent = fmt(obj.v); },
      complete: function () { el.textContent = fmt(target); }
    });
  }

  window.Motion = { reveal: reveal, pop: pop, fadeIn: fadeIn, pulse: pulse, grow: grow, countUp: countUp };

  /* ---------- Глобальные эффекты ---------- */

  /* Полоса под активной вкладкой плавно «переезжает» с предыдущей страницы на текущую */
  function navIndicator() {
    var wrap = document.querySelector('.nav-tabs-wrap');
    var act = wrap && wrap.querySelector('a.active');
    if (!act) return;
    var ind = document.createElement('span');
    ind.className = 'nav-ind';
    wrap.appendChild(ind);
    wrap.classList.add('has-ind');

    function geo() {
      var w = wrap.getBoundingClientRect(), a = act.getBoundingClientRect();
      return { x: a.left - w.left + 12, w: a.width - 24 };
    }
    function place(g) {
      ind.style.width = g.w + 'px';
      ind.style.transform = 'translateX(' + g.x + 'px)';
    }
    function save(g) { try { sessionStorage.setItem('nav_ind', JSON.stringify(g)); } catch (e) { } }

    var cur = geo(), prev = null;
    try { prev = JSON.parse(sessionStorage.getItem('nav_ind')); } catch (e) { }
    save(cur);

    if (ok && prev && typeof prev.x === 'number' && (Math.abs(prev.x - cur.x) > 1 || Math.abs(prev.w - cur.w) > 1)) {
      place(prev);
      anime({ targets: ind, translateX: [prev.x, cur.x], width: [prev.w, cur.w], duration: 380, easing: 'easeOutCubic' });
    } else {
      place(cur);
    }
    function relayout() { cur = geo(); place(cur); save(cur); }
    window.addEventListener('resize', relayout);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(relayout);
  }

  /* Логотип «прорисовывается» один раз за сессию (на странице входа — всегда) */
  function logoIntro() {
    var mark = document.querySelector('.brand-mark, .auth-ic');
    if (!mark || !ok) return;
    var isAuth = mark.classList.contains('auth-ic');
    try {
      if (!isAuth && sessionStorage.getItem('logo_seen')) return;
      sessionStorage.setItem('logo_seen', '1');
    } catch (e) { }
    var a = mark.querySelector('.logo-a'), dot = mark.querySelector('.logo-dot');
    if (a) anime({ targets: a, strokeDashoffset: [anime.setDashoffset, 0], duration: 650, easing: 'easeInOutSine' });
    if (dot) anime({ targets: dot, scale: [0, 1], duration: 420, delay: 450, easing: 'easeOutBack' });
  }

  function init() {
    navIndicator();
    logoIntro();
    var card = document.querySelector('.auth-card');
    if (card) pop(card, { y: 12, scale: 0.985, duration: 320 });

    document.addEventListener('click', function (e) {
      var b = e.target.closest && e.target.closest('.theme-toggle');
      if (!b || !ok) return;
      var svg = b.querySelector('svg');
      if (svg) anime({ targets: svg, rotate: [-90, 0], opacity: [0, 1], duration: 320, easing: 'easeOutCubic' });
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
