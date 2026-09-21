import Foundation

// JavaScript injected into the Instagram page at document-end.
// NOTE: deliberately contains no backslashes, so it survives a Swift multiline literal.
let reelBridgeJS = """
window.__rc = (function () {
  var T0 = performance.now();   // script injection, i.e. document-end
  function post(m) { try { window.webkit.messageHandlers.rc.postMessage(String(m)); } catch (e) {} }

  function labelOf(el) {
    var a = el.getAttribute && el.getAttribute('aria-label');
    return a ? a.trim().toLowerCase() : '';
  }
  function allLabeled(root) {
    return Array.prototype.slice.call((root || document).querySelectorAll('[aria-label]'));
  }
  function matchAny(label, list) {
    if (!label) return false;
    for (var i = 0; i < list.length; i++) {
      if (label === list[i] || label.indexOf(list[i]) === 0) return true;
    }
    return false;
  }
  function visible(el) {
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  // Prefer a control with a real box, but accept a collapsed one: stripping the post
  // view can leave a chevron measuring 0x0 while still being perfectly clickable,
  // and we only ever click these programmatically.
  function preferVisible(matches) {
    for (var i = 0; i < matches.length; i++) if (visible(matches[i])) return matches[i];
    return matches.length ? matches[0] : null;
  }
  function target(el) { return el.closest('button, [role="button"], a, div[tabindex]') || el; }

  // A single real click(). Dispatching a synthetic 'click' as well would toggle
  // the button twice and land back where it started.
  // Our own clicks must not look like the viewer tapping to pause - the click
  // listener that records lastClick suppresses auto-resume for 4s, so like/save
  // were silently muting our own playback watchdog.
  var synthetic = false;

  function fire(el) {
    var t = target(el);
    synthetic = true;
    try { t.click(); } catch (e) {}
    synthetic = false;
    return t;
  }

  // Retry path for buttons that ignore click() and listen lower down. Only ever
  // used after a click() demonstrably did nothing, so it cannot double-toggle.
  function firePointer(el) {
    var t = target(el);
    var r = t.getBoundingClientRect();
    var o = { bubbles: true, cancelable: true, composed: true, view: window,
              clientX: Math.round(r.left + r.width / 2),
              clientY: Math.round(r.top + r.height / 2),
              button: 0, buttons: 1, pointerId: 1, pointerType: 'mouse', isPrimary: true };
    ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(function (type) {
      try {
        var E = (type.indexOf('pointer') === 0) ? PointerEvent : MouseEvent;
        t.dispatchEvent(new E(type, o));
      } catch (e) {}
    });
    return t;
  }

  // Instagram localises aria-labels, so match English + Bulgarian + a few common others.
  var NEXT   = ['next', 'следващ', 'напред', 'siguiente'];
  var SAVE   = ['save', 'запази', 'запазване', 'guardar'];
  var UNSAVE = ['remove', 'премахни', 'отстрани', 'quitar'];
  var LIKE   = ['like', 'харесай', 'харесване'];
  var LIKED  = ['unlike', 'не харесвай', 'премахни харесването'];
  var SHARE  = ['share', 'сподели', 'споделяне'];
  var MORE   = ['more', 'още', 'повече'];

  function activeVideo() {
    var vids = Array.prototype.slice.call(document.querySelectorAll('video'));
    var cy = window.innerHeight / 2, best = null, bd = 1e9;
    vids.forEach(function (v) {
      var r = v.getBoundingClientRect();
      if (r.height < 40) return;
      var d = Math.abs((r.top + r.bottom) / 2 - cy);
      if (d < bd) { bd = d; best = v; }
    });
    return best;
  }

  // Identify the reel nearest the centre of the viewport by its author link
  // (Instagram labels these '<username> reels'). Used to prove F9 really advanced.
  function currentReel() {
    var links = allLabeled(document).filter(function (e) {
      return e.tagName === 'A' && labelOf(e).indexOf(' reels') > 0 && visible(e);
    });
    var cy = window.innerHeight / 2, best = '(none)', bd = 1e9;
    links.forEach(function (a) {
      var r = a.getBoundingClientRect();
      var d = Math.abs((r.top + r.bottom) / 2 - cy);
      if (d < bd) { bd = d; best = labelOf(a); }
    });
    return best;
  }

  function scroller() {
    var el = activeVideo();
    while (el) {
      var s = getComputedStyle(el);
      if ((s.overflowY === 'auto' || s.overflowY === 'scroll') && el.scrollHeight > el.clientHeight + 20) return el;
      el = el.parentElement;
    }
    return document.scrollingElement || document.documentElement;
  }

  function toast(msg, ok) {
    if (!document.body) return;
    var d = document.getElementById('__rc_toast');
    if (!d) {
      d = document.createElement('div');
      d.id = '__rc_toast';
      d.style.cssText = 'position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:2147483647;' +
        'padding:7px 15px;border-radius:999px;color:#fff;pointer-events:none;transition:opacity .25s;' +
        'font:600 12px -apple-system,system-ui,sans-serif;backdrop-filter:blur(10px)';
      document.body.appendChild(d);
    }
    d.textContent = msg;
    d.style.background = ok ? 'rgba(18,18,18,.85)' : 'rgba(170,32,32,.9)';
    d.style.opacity = '1';
    clearTimeout(d.__t);
    d.__t = setTimeout(function () { d.style.opacity = '0'; }, 1300);
  }

  // ---- reel geometry (cached) -------------------------------------------------
  //
  // Measuring every card costs a forced layout per card, and the feed only grows.
  // Cache it and rebuild only when something could actually have moved: a card
  // added or removed, a restyle that changed sizes, or a resize. Before this, one
  // F9 paid for three or four full measurement passes.

  var reelCache = [], reelsDirty = true;
  var lastChildCount = -1, lastFirst = null, lastLast = null;
  var feedObserver = null, feedObserved = null;

  // Instagram RECYCLES the feed: it drops cards off the top as it appends to the
  // bottom, so children.length barely moves and a count-only check never fires.
  // Watching the container's own childList catches it exactly; the first/last
  // child identity check is the cheap belt-and-braces (reference compare, no layout).
  function watchFeed() {
    var c = feedContainer();
    if (!c || c === feedObserved) return;
    if (feedObserver) feedObserver.disconnect();
    feedObserver = new MutationObserver(function () { invalidateReels(); });
    feedObserver.observe(c, { childList: true });
    feedObserved = c;
    invalidateReels();
    post('feed observer attached');
  }

  function invalidateReels() { reelsDirty = true; }

  function rebuildReels(c) {
    var cr = c.getBoundingClientRect();
    var out = [];
    var kids = c.children;
    for (var i = 0; i < kids.length; i++) {
      var card = kids[i];
      // Only in-flow children are real reel cards. Anything we took out of flow,
      // or that Instagram positions absolutely, contributes nothing to scrollHeight
      // yet still reports a bounding rect - counting one as a card invents a
      // phantom reel far beyond the reachable scroll range.
      if (card.__rcHide) continue;
      var v = card.querySelector('video');
      if (!v) continue;
      var pos = getComputedStyle(card).position;
      if (pos === 'absolute' || pos === 'fixed') continue;
      var r = card.getBoundingClientRect();
      out.push({ v: v, card: card, top: Math.round(c.scrollTop + (r.top - cr.top)) });
    }
    out.sort(function (a, b) { return a.top - b.top; });
    return out.filter(function (o, i) { return i === 0 || o.top - out[i - 1].top > 4; });
  }

  function reels(c) {
    var n = c.children.length;                 // all cheap, force no layout
    var f = c.firstElementChild, l = c.lastElementChild;
    if (n !== lastChildCount || f !== lastFirst || l !== lastLast) {
      lastChildCount = n; lastFirst = f; lastLast = l; reelsDirty = true;
    }
    if (reelsDirty || !reelCache.length) { reelCache = rebuildReels(c); reelsDirty = false; }
    return reelCache;
  }

  function activeIndex(list, c) {
    var best = 0, bd = 1e9, st = c.scrollTop;
    for (var i = 0; i < list.length; i++) {
      var d = Math.abs(list[i].top - st);
      if (d < bd) { bd = d; best = i; }
    }
    return best;
  }

  window.addEventListener('resize', invalidateReels);

  // ---- F9: advance one reel -------------------------------------------------

  var retrying = false;

  function nextFallback() {
    var chev = preferVisible(allLabeled(document).filter(function (e) {
      return matchAny(labelOf(e), NEXT);
    }));
    if (chev) { fire(chev); post('next: chevron button' + (visible(chev) ? '' : ' (collapsed box)')); return; }
    ['keydown', 'keyup'].forEach(function (t) {
      document.dispatchEvent(new KeyboardEvent(t, {
        key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, which: 40, bubbles: true, cancelable: true
      }));
    });
    post('next: no feed container, sent ArrowDown');
  }

  function maxScroll(c) { return Math.max(0, c.scrollHeight - c.clientHeight); }

  // Assign and read straight back. scrollTop applies synchronously, so a clamped
  // value here is immediate proof that the target was unreachable.
  function jump(c, goal) {
    var want = Math.min(Math.max(0, goal), maxScroll(c));
    c.scrollTop = want;
    return { want: want, got: c.scrollTop };
  }

  // At the bottom, assigning scrollTop clamps and emits NO scroll event, so
  // Instagram's infinite-scroll observer never fires and the feed can sit there
  // not growing. Move for real, then come back.
  function provokeLoad(c) {
    var max = maxScroll(c);
    if (c.scrollTop < max - 4) return;
    // Same task only: the browser paints once per frame, so this position is
    // never rendered and the viewer sees nothing.
    c.scrollTop = Math.max(0, max - 60);
    try { c.dispatchEvent(new Event('scroll')); } catch (e) {}
    c.scrollTop = maxScroll(c);
  }

  // Keep this many reels loaded ahead of the one on screen, so fast pressing never
  // runs into the end of the feed.
  var TARGET_AHEAD = 50;

  // Make Instagram think we are at the bottom so it fetches the next page, without
  // the user ever seeing it. Both assignments happen in one task, and the browser
  // paints only once per frame - so the bottom position is never rendered. The
  // scroll event is dispatched while scrollTop genuinely reads as the bottom, so a
  // handler that checks the position is satisfied.
  function nudgeLoader(c, restoreTo) {
    var max = maxScroll(c);
    if (max <= restoreTo + 4) return false;
    c.scrollTop = max;
    try { c.dispatchEvent(new Event('scroll')); } catch (e) {}
    try { window.dispatchEvent(new Event('scroll')); } catch (e) {}
    c.scrollTop = restoreTo;
    return true;
  }

  // NOTE: no scroll-excursion prefetching. Instagram paginates from an
  // IntersectionObserver, which only recomputes on a real rendering pass, so any
  // excursion that actually works is an excursion the viewer can see - it showed
  // up as a reel flashing past and snapping back. Smoothness wins; we ask
  // invisibly and otherwise let Instagram set the pace.

  function topUp(c) {
    var list = reels(c);
    if (!list.length) return;
    var ahead = list.length - 1 - activeIndex(list, c);
    if (ahead >= TARGET_AHEAD) return;
    var at = c.scrollTop;
    // Several nudges per pass: Instagram serves one page at a time, and from cold
    // we need many pages to build a 50-reel buffer.
    for (var i = 0; i < 3; i++) nudgeLoader(c, at);
    provokeLoad(c);
  }

  function pickGoal(c, force) {
    if (force) invalidateReels();
    var list = reels(c);
    if (!list.length) return null;
    var from = c.scrollTop;
    var goal = null, gi = -1;
    for (var i = 0; i < list.length; i++) {
      if (list[i].top > from + 8) { goal = list[i].top; gi = i; break; }
    }
    var exact = (goal !== null);
    if (!exact) goal = from + (c.clientHeight || window.innerHeight);
    return { list: list, from: from, goal: goal, gi: gi, exact: exact };
  }

  // One coalesced housekeeping pass however many presses arrive - ten rapid
  // presses must not queue ten strip/size/playback sweeps.
  var hkPending = false;
  function afterPress() {
    if (hkPending) return;
    hkPending = true;
    requestAnimationFrame(function () {
      setTimeout(function () {
        hkPending = false;
        watchFeed();
        if (isolate() + fillVideo()) invalidateReels();
        enforcePlayback(true);
        topUp(c);          // off the hot path: it writes scrollTop and forces layout
      }, 0);
    });
  }

  var pendingAdvance = false;

  function armPendingAdvance(c, atTop) {
    provokeLoad(c);
    if (pendingAdvance) return;
    pendingAdvance = true;
    var since = Date.now();
    toast('Loading more reels', true);
    var timer = setInterval(function () {
      provokeLoad(c);
      invalidateReels();
      if (reels(c).some(function (o) { return o.top > atTop + 8; })) {
        clearInterval(timer); pendingAdvance = false;
        post('next: more reels arrived after ' + (Date.now() - since) + 'ms, taking the press');
        next();
      } else if (Date.now() - since > 20000) {
        clearInterval(timer); pendingAdvance = false;
        toast('No more reels', false);
        post('next: Instagram served nothing new for 20s');
      }
    }, 400);
  }

  function next() {
    var t0 = performance.now();

    // Saved mode is a post view, not a feed: drive its Next control directly.
    if (mode() === 'saved') {
      if (inSaved()) openFirstSaved(); else savedNext(0);
      return;
    }

    var c = feedContainer();
    if (!c) {
      setTimeout(function () {
        isolate(); fillVideo(); invalidateReels();
        if (feedContainer()) { post('next: feed was not ready, retrying'); next(); }
        else nextFallback();
      }, 300);
      return;
    }

    var r = pickGoal(c, false);
    if (!r) { isolate(); fillVideo(); r = pickGoal(c, true); }
    if (!r) { nextFallback(); return; }

    // A target more than two screens away means the cache is describing cards that
    // no longer exist. Rebuild before trusting it.
    if (r.exact && r.goal - r.from > 2.2 * c.clientHeight) {
      r = pickGoal(c, true) || r;
    }

    var res = jump(c, r.goal);
    var healed = '';

    // Clamped, or did not move at all on an exact target: the geometry was stale.
    // Rebuild and retake the press now, rather than repeating the same impossible
    // target on every future press - which is exactly how it froze before.
    if (Math.abs(res.got - res.want) > 4 || (r.exact && res.got === r.from)) {
      var r2 = pickGoal(c, true);
      if (r2) { res = jump(c, r2.goal); r = r2; healed = ' HEALED'; }
    }

    var av = (r.gi >= 0 && r.list[r.gi]) ? r.list[r.gi].v : null;
    var ready = -1;
    if (av) { av.muted = wantMuted; ready = av.readyState; play(av); }
    else { enforcePlayback(true); }

    var buf = r.list.length - 1 - (r.gi >= 0 ? r.gi : r.list.length - 1);
    post('next: ' + (r.exact ? 'card' : 'step') + ' -> ' + r.goal + ' landed ' + res.got +
         ' sync=' + Math.round(performance.now() - t0) + 'ms ready=' + ready +
         ' ahead=' + buf + '/' + r.list.length + healed);

    afterPress();

    // Past the end of the loaded list the nudge cannot move anything, it only
    // prompts Instagram to fetch more. Take the press again once the cards land.
    // End of the loaded feed: the press has nothing to advance to yet. Rather than
    // dropping it - which reads as 'F9 did nothing' - remember it, keep prodding
    // Instagram, and take the press the moment new reels arrive.
    if (!r.exact && res.got === r.from) armPendingAdvance(c, res.got);
  }

  // ---- saved mode (cmd-F8) ------------------------------------------------------
  //
  // The saved collection is a grid of posts, not a scrolling video feed, so it has
  // no feed container. Opening the first item gives the post view, which carries a
  // real Next control - and next() already falls back to that. The mode is kept in
  // localStorage because navigating reloads the page and wipes all script state.

  function isUserPath(h) {
    if (!h || h.charAt(0) !== '/' || h.charAt(h.length - 1) !== '/') return false;
    var mid = h.substring(1, h.length - 1);
    if (!mid.length || mid.indexOf('/') >= 0) return false;
    return ['explore', 'reels', 'direct', 'accounts', 'stories', 'p', 'tv',
            'your_activity', 'legal'].indexOf(mid) < 0;
  }

  function profileUser() {
    var links = Array.prototype.slice.call(document.querySelectorAll('a[href]'));
    for (var i = 0; i < links.length; i++) {
      var h = links[i].getAttribute('href');
      if (isUserPath(h) && links[i].querySelector('img')) return h.substring(1, h.length - 1);
    }
    for (var j = 0; j < links.length; j++) {
      var h2 = links[j].getAttribute('href');
      if (isUserPath(h2) && labelOf(links[j]).indexOf('profile') >= 0) {
        return h2.substring(1, h2.length - 1);
      }
    }
    return null;
  }

  function mode() { try { return localStorage.getItem('__rc_mode') || 'reels'; } catch (e) { return 'reels'; } }
  function setMode(m) { try { localStorage.setItem('__rc_mode', m); } catch (e) {} }

  function inSaved() { return location.pathname.indexOf('/saved/') >= 0; }

  // The mode lives in localStorage so it survives the navigation, but the app always
  // loads /reels/ on launch - so reconcile against the real URL at injection time,
  // or a restart leaves us "in saved mode" while sitting on the reels feed.
  if (location.pathname.indexOf('/reels') === 0) setMode('reels');

  var savedOpening = '', savedQuiet = 0;

  function openFirstSaved() {
    if (mode() !== 'saved' || !inSaved()) return;
    var a = document.querySelector('main a[href*="/reel/"]') ||
            document.querySelector('a[href*="/reel/"]') ||
            document.querySelector('main a[href*="/p/"]');
    if (!a) {
      if (Date.now() - savedQuiet > 3000) { savedQuiet = Date.now(); post('saved: grid not ready yet'); }
      return;
    }
    var href = a.getAttribute('href');
    if (href === savedOpening) return;   // already clicked it; the sweep must not re-click
    savedOpening = href;
    post('saved: opening ' + href);
    fire(a);
  }

  // The saved collection mixes photos and reels and Instagram offers no reels-only
  // view, so skip straight past anything without a video.
  function savedNext(depth) {
    nextFallback();
    setTimeout(function () {
      var v = activeVideo();
      if (!v && (depth || 0) < 12) {
        post('saved: not a reel, skipping');
        savedNext((depth || 0) + 1);
      } else {
        enforcePlayback(true);
      }
    }, 650);
  }

  function toggleMode() {
    if (mode() === 'saved') {
      setMode('reels');
      post('mode -> reels');
      location.href = '/reels/';
      return;
    }
    var u = profileUser();
    if (!u) { toast('Could not find your profile', false); post('saved: no profile link found'); return; }
    setMode('saved');
    post('mode -> saved (/' + u + '/saved/all-posts/)');
    location.href = '/' + u + '/saved/all-posts/';
  }

  // ---- explicit start / recovery (cmd-F9) ---------------------------------------

  function recover() {
    invalidateReels();
    injectCSS(); isolate(); fillVideo();
    invalidateReels();
    watchFeed();
    var c = feedContainer();
    if (c) {
      var list = reels(c);
      if (list.length) {
        // Realign onto a real card, in case a wedged position left us between two.
        var ai = activeIndex(list, c);
        c.scrollTop = Math.min(list[ai].top, maxScroll(c));
      }
    }
    enforcePlayback(true);
    retryPlay();
    post('recover: reels=' + (c ? reels(c).length : 0) +
         ' scrollTop=' + (c ? c.scrollTop : -1) + ' max=' + (c ? maxScroll(c) : -1));
  }

  function health() {
    var c = feedContainer();
    if (!c) return 'DEAD no-container';
    // Measure fresh. A reload throws away the feed position, so it must never be
    // triggered by a merely stale cache - only by geometry that is really broken.
    invalidateReels();
    var list = reels(c);
    if (!list.length) return 'DEAD no-reels';
    // A genuine wedge means nothing in the list can be scrolled to at all. One
    // stray entry past the end must never condemn a working page - a reload throws
    // away the feed position.
    var max = maxScroll(c);
    var reachable = 0;
    for (var i = 0; i < list.length; i++) if (list[i].top <= max + 4) reachable++;
    if (!reachable) return 'DEAD geometry: 0 of ' + list.length + ' reachable (max=' + max + ')';
    var v = list[activeIndex(list, c)].v;
    return 'OK reels=' + list.length + ' paused=' + v.paused + ' ready=' + v.readyState;
  }

  // ---- F7 / F8: the reel's action rail ---------------------------------------

  function isLikeBtn(l) { return matchAny(l, LIKE) || matchAny(l, LIKED); }

  // The action rail is the nearest ancestor of the playing video that owns both
  // the Like and Share icons. Scoping to it stops us hitting another reel.
  function railOf(video) {
    var node = video;
    for (var up = 0; up < 16 && node; up++) {
      var ls = allLabeled(node);
      var hasLike = ls.some(function (e) { return isLikeBtn(labelOf(e)); });
      var hasShare = ls.some(function (e) { return matchAny(labelOf(e), SHARE); });
      if (hasLike && hasShare) return node;
      node = node.parentElement;
    }
    return null;
  }

  function activeRail() { var v = activeVideo(); return v ? railOf(v) : null; }

  // Always re-queried, never cached: React unmounts these icons and mounts fresh
  // nodes when the state flips, so a held reference keeps its stale aria-label
  // forever - which is what made every save and like report a false failure.
  function findSave(rail) {
    if (rail) {
      var tagged = allLabeled(rail).filter(function (e) {
        var l = labelOf(e); return (matchAny(l, SAVE) || matchAny(l, UNSAVE)) && visible(e);
      });
      if (tagged.length) return [tagged[0], 'label-in-rail'];

      // Instagram orders the rail Like, Comment, Share, Save, More. If the UI is
      // localised past our label list, take whatever sits between Share and More.
      var icons = allLabeled(rail).filter(visible);
      var iShare = -1, iMore = -1;
      for (var i = 0; i < icons.length; i++) {
        var l = labelOf(icons[i]);
        if (iShare < 0 && matchAny(l, SHARE)) iShare = i;
        else if (iShare >= 0 && iMore < 0 && matchAny(l, MORE)) iMore = i;
      }
      if (iShare >= 0 && iMore === iShare + 2) return [icons[iShare + 1], 'between-share-and-more'];
    }
    var any = preferVisible(allLabeled(document).filter(function (e) {
      var l = labelOf(e); return matchAny(l, SAVE) || matchAny(l, UNSAVE);
    }));
    return any ? [any, 'label-document-wide'] : [null, rail ? 'rail-no-save' : 'no-rail'];
  }

  function findLike(rail) {
    var hit = preferVisible(allLabeled(rail || document).filter(function (e) {
      return isLikeBtn(labelOf(e));
    }));
    return hit ? [hit, rail ? 'rail' : 'document-wide'] : [null, 'not-found'];
  }

  // Two-stage check. Re-finds the button rather than holding a reference, because
  // React unmounts the old icon and mounts a fresh node when the state flips - a
  // held reference keeps its stale aria-label forever and reports a false failure.
  //
  // The re-find is pinned to the rail we actually clicked, not to whatever reel is
  // centred now. Re-resolving by position could land on a neighbouring reel and
  // make the retry like or save the wrong one.
  function confirmToggle(name, find, isDone, before, okWord, rail) {
    function scope() { return (rail && document.contains(rail)) ? rail : activeRail(); }
    setTimeout(function () {
      var el = find(scope())[0];
      var mid = el ? labelOf(el) : '(gone)';
      if (el && (isDone(mid) || mid !== before)) {
        toast(okWord, true); post(name + ': ' + before + ' -> ' + mid + ' OK');
        return;
      }
      // Only retry when the button is demonstrably still in its original state,
      // so the retry can never toggle something that already succeeded.
      if (el && mid === before) {
        firePointer(el);
        post(name + ': click() had no effect, retrying with pointer events');
      }
      setTimeout(function () {
        var el2 = find(scope())[0];
        var now = el2 ? labelOf(el2) : '(gone)';
        var ok = el2 ? (isDone(now) || now !== before) : false;
        toast(ok ? okWord : (name + ' failed'), ok);
        post(name + ': ' + before + ' -> ' + now + (ok ? ' OK (pointer retry)' : ' FAILED'));
      }, 1100);
    }, 800);
  }

  function save() {
    var rail = activeRail();
    var r = findSave(rail), b = r[0], how = r[1];
    if (!b) { toast('Save button not found', false); post('save: NOT FOUND (' + how + ')'); return; }
    var before = labelOf(b);
    if (matchAny(before, UNSAVE)) { toast('Already saved', true); post('save: already saved'); return; }
    fire(b);
    post('save: clicked via ' + how + ' (label=' + before + ')');
    confirmToggle('save', findSave, function (l) { return matchAny(l, UNSAVE); }, before, 'Saved', rail);
  }

  // ---- strip the page down to the reel ---------------------------------------
  //
  // Two hiding mechanisms on purpose:
  //   display:none     for page chrome outside the feed - it must not take space
  //   visibility:hidden for the reel's own overlay (author, caption, action rail)
  //                     - invisible, but keeps its layout box and click handlers,
  //                       which is what lets F7/F8 still drive those buttons.

  var cleanOn = true;

  function hideNone(el) {
    if (el.__rcHide === 'none') return 0;
    el.style.setProperty('display', 'none', 'important');
    el.__rcHide = 'none';
    return 1;
  }
  function hideVis(el) {
    if (el.__rcHide === 'vis') return 0;
    el.style.setProperty('visibility', 'hidden', 'important');
    el.__rcHide = 'vis';
    return 1;
  }
  function isToast(el) { return el.id === '__rc_toast'; }

  function feedContainer() {
    var c = scroller();
    if (!c || c === document.documentElement || c === document.scrollingElement) return null;
    return c;
  }

  // How many cards around the active one get processed. Work per sweep must not
  // grow with the length of the feed - Instagram appends forever, and an unbounded
  // sweep is what made the page janky (and F9 feel dropped) after a long session.
  var BACK = 2, AHEAD = 8;

  // Post view (saved mode): there is no feed container, so strip around the single
  // <video> instead. Everything off the path from <body> down to it is hidden with
  // visibility + absolute, never display:none - the post view's own Next chevron is
  // one of those elements and F9 needs its layout box to survive.
  function isolatePost() {
    var v = activeVideo();
    if (!v) return 0;
    var n = 0;

    var path = new Set();
    var e = v;
    while (e && e !== document.body) { path.add(e); e = e.parentElement; }
    path.add(document.body);

    path.forEach(function (node) {
      Array.prototype.slice.call(node.children).forEach(function (ch) {
        if (path.has(ch) || isToast(ch) || ch.__rcHide) return;
        ch.style.setProperty('visibility', 'hidden', 'important');
        ch.style.setProperty('position', 'absolute', 'important');
        ch.__rcHide = 'vis';
        n++;
      });
    });

    [document.documentElement, document.body].forEach(function (el) {
      if (!el) return;
      el.style.setProperty('overflow', 'hidden', 'important');
      el.style.setProperty('margin', '0', 'important');
      el.style.setProperty('padding', '0', 'important');
      el.style.setProperty('width', '100%', 'important');
      el.style.setProperty('height', '100%', 'important');
    });

    var f = v;
    while (f && f !== document.body) {
      if (!f.__rcFill) {
        FILL.forEach(function (k) { f.style.setProperty(k, FILLVAL[k], 'important'); });
        f.__rcFill = true;
        n++;
      }
      f = f.parentElement;
    }

    if (n) post('clean(post): hid/expanded ' + n + ' element(s)');
    return n;
  }

  function isolate() {
    if (!cleanOn || !document.body) return 0;
    var c = feedContainer();
    if (!c) return isolatePost();
    var n = 0;

    // 1. everything off the path from <body> down to the feed container
    var node = c;
    while (node && node !== document.body) {
      var p = node.parentElement;
      if (!p) break;
      var kids = Array.prototype.slice.call(p.children);
      for (var i = 0; i < kids.length; i++) {
        if (kids[i] !== node && !isToast(kids[i])) n += hideNone(kids[i]);
      }
      node = p;
    }

    // 2. inside the feed: keep only the <video> elements and their ancestors.
    //    Off-path children are hidden AND taken out of flow - otherwise the
    //    (invisible) action-rail column still shrinks the reel via flexbox.
    //    Descendants inherit visibility:hidden, so we never recurse into them.
    var list = reels(c);
    if (!list.length) return n;
    var ai = activeIndex(list, c);
    var lo = Math.max(0, ai - BACK), hi = Math.min(list.length - 1, ai + AHEAD);

    var keep = new Set();
    keep.add(c);
    // Every card stays in flow and visible, even outside the window - hiding one
    // would collapse the feed's scroll height. We simply do not descend into the
    // far ones until they come close.
    for (var j = 0; j < list.length; j++) keep.add(list[j].card);
    for (var k = lo; k <= hi; k++) {
      var e = list[k].v;
      while (e && e !== c) { keep.add(e); e = e.parentElement; }
    }

    keep.forEach(function (node) {
      Array.prototype.slice.call(node.children).forEach(function (ch) {
        if (keep.has(ch) || isToast(ch) || ch.__rcHide) return;
        ch.style.setProperty('visibility', 'hidden', 'important');
        ch.style.setProperty('position', 'absolute', 'important');
        ch.__rcHide = 'vis';
        n++;
      });
    });

    if (n) post('clean: hid ' + n + ' element(s)');
    return n;
  }

  // Instagram letterboxes the reel inside a centred card. Force every ancestor
  // between the <video> and the feed container to fill, so the reel is edge to edge.
  var FILL = ['width', 'height', 'max-width', 'max-height', 'min-width',
              'min-height', 'margin', 'padding', 'border-radius', 'border-width'];
  var FILLVAL = { 'width': '100%', 'height': '100%', 'max-width': 'none', 'max-height': 'none',
                  'min-width': '0', 'min-height': '0', 'margin': '0', 'padding': '0',
                  'border-radius': '0', 'border-width': '0' };

  // The feed container carries a 32px top padding and its ancestors cap the width.
  // Instagram paginates from an IntersectionObserver rooted on the feed container,
  // so what it treats as "on screen" is that container's box - not the window. Make
  // the container VIEWPORTS screens tall while each card stays exactly one screen:
  // body has overflow:hidden so we still see only the top screen, but Instagram now
  // believes several reels are in view and fetches much further ahead. The matching
  // padding-bottom keeps the final cards scrollable to the top.
  // REVERTED to 1. At 5, Instagram's own player treats five reels as on screen and
  // plays the middle one - pausing the reel actually being watched while our enforcer
  // plays it. Two controllers fighting over one element, visible as stalled playback.
  // Eager loading is not worth that; Instagram sets the pace.
  var VIEWPORTS = 1;
  function vh() { return window.innerHeight; }

  function fillOuter(c) {
    // Inline + important beats anything Instagram sets, including its own inline styles.
    [document.documentElement, document.body].forEach(function (e) {
      if (!e) return;
      e.style.setProperty('overflow', 'hidden', 'important');
      e.style.setProperty('margin', '0', 'important');
      e.style.setProperty('padding', '0', 'important');
      e.style.setProperty('width', '100%', 'important');
      e.style.setProperty('max-width', 'none', 'important');
    });
    if (c.__rcFill) return;
    ['padding', 'margin', 'border-radius', 'border-width'].forEach(function (k) { c.style.setProperty(k, '0', 'important'); });
    c.style.setProperty('max-width', 'none', 'important');
    c.style.setProperty('width', '100%', 'important');
    c.style.setProperty('height', (vh() * VIEWPORTS) + 'px', 'important');
    c.style.setProperty('max-height', 'none', 'important');
    c.style.setProperty('padding-bottom', (vh() * (VIEWPORTS - 1)) + 'px', 'important');
    c.style.setProperty('overflow-y', 'scroll', 'important');
    c.__rcFill = true;
    var e = c.parentElement;
    while (e && e !== document.documentElement) {
      if (!e.__rcFill) {
        ['padding', 'margin', 'border-width'].forEach(function (k) { e.style.setProperty(k, '0', 'important'); });
        e.style.setProperty('max-width', 'none', 'important');
        e.style.setProperty('width', '100%', 'important');
        e.__rcFill = true;
      }
      e = e.parentElement;
    }
  }

  function fillVideo() {
    if (!cleanOn) return 0;
    var c = feedContainer();
    if (!c) return 0;
    var n = 0;
    fillOuter(c);
    var list = reels(c);
    if (!list.length) return n;
    var ai = activeIndex(list, c);
    var lo = Math.max(0, ai - BACK), hi = Math.min(list.length - 1, ai + AHEAD);
    for (var k = lo; k <= hi; k++) {
      var e = list[k].v;
      while (e && e !== c) {
        if (!e.__rcFill) {
          FILL.forEach(function (key) { e.style.setProperty(key, FILLVAL[key], 'important'); });
          // The card itself is one screen tall in pixels - not 100%, which would now
          // resolve against the deliberately oversized container.
          if (e.parentElement === c) e.style.setProperty('height', vh() + 'px', 'important');
          e.__rcFill = true;
          n++;
        }
        e = e.parentElement;
      }
    }
    if (n) post('fill: expanded ' + n + ' wrapper(s)');
    return n;
  }

  // Make the reel fill the panel and kill any leftover page scrollbars/background.
  function injectCSS() {
    if (document.getElementById('__rc_css')) return;
    if (!document.head) return;
    var st = document.createElement('style');
    st.id = '__rc_css';
    st.textContent =
      'html,body{background:#000 !important;overflow:hidden !important;margin:0 !important;' +
      'padding:0 !important;width:100% !important;max-width:none !important;border:0 !important}' +
      '::-webkit-scrollbar{width:0 !important;height:0 !important;display:none !important}' +
      'video{visibility:visible !important;object-fit:cover !important;background:#000 !important}';
    document.head.appendChild(st);
    post('clean: css injected');
  }

  function restoreAll() {
    var n = 0;
    document.querySelectorAll('*').forEach(function (el) {
      if (el.__rcHide) {
        if (el.__rcHide === 'none') { el.style.removeProperty('display'); }
        else { el.style.removeProperty('visibility'); el.style.removeProperty('position'); }
        el.__rcHide = null;
        n++;
      }
      if (el.__rcFill) {
        FILL.forEach(function (k) { el.style.removeProperty(k); });
        el.__rcFill = false;
      }
    });
    var css = document.getElementById('__rc_css');
    if (css) css.remove();
    post('clean: restored ' + n + ' element(s)');
  }

  // ---- F7: like the reel ------------------------------------------------------
  function like() {
    var rail = activeRail();
    var r = findLike(rail), b = r[0], how = r[1];
    if (!b) { toast('Like button not found', false); post('like: NOT FOUND'); return; }
    var before = labelOf(b);
    // 'unlike' means it is already liked; F7 is like-only, never an accidental un-like.
    if (matchAny(before, LIKED)) { toast('Already liked', true); post('like: already liked'); return; }
    fire(b);
    post('like: clicked via ' + how + ' (label=' + before + ')');
    confirmToggle('like', findLike, function (l) { return matchAny(l, LIKED); }, before, 'Liked', rail);
  }

  // ---- diagnostics ----------------------------------------------------------
  function dump() {
    var out = allLabeled(document).map(function (e) {
      return (visible(e) ? '*' : ' ') + '<' + e.tagName.toLowerCase() + '>' + e.getAttribute('aria-label');
    });
    var v = activeVideo();
    var geo = v ? (function () {
      var r = v.getBoundingClientRect();
      return ' video=' + Math.round(r.width) + 'x' + Math.round(r.height) +
             ' at(' + Math.round(r.left) + ',' + Math.round(r.top) + ')' +
             ' viewport=' + window.innerWidth + 'x' + window.innerHeight +
             ' paused=' + v.paused + ' ready=' + v.readyState +
             ' t=' + v.currentTime.toFixed(2);
    })() : ' video=none';
    post('DUMP url=' + location.pathname + ' videos=' + document.querySelectorAll('video').length +
         geo + ' labeled=' + out.length + ' (* = visible) :: ' + out.join('  |  '));
  }

  // Report the layout chain from the playing video up to the feed container,
  // so we can see exactly which ancestor is still constraining the reel.
  function chain() {
    var v = activeVideo();
    var c = feedContainer();
    if (!v || !c) { post('CHAIN: no video or no container'); return; }
    var out = [], e = v, i = 0;
    while (e && i < 40) {
      var r = e.getBoundingClientRect();
      var st = getComputedStyle(e);
      out.push(i + ':' + e.tagName.toLowerCase() +
               ' ' + Math.round(r.width) + 'x' + Math.round(r.height) +
               '@' + Math.round(r.left) + ',' + Math.round(r.top) +
               ' disp=' + st.display + ' pos=' + st.position +
               ' ar=' + st.aspectRatio + ' flex=' + st.flex +
               ' ai=' + st.alignItems + ' jc=' + st.justifyContent +
               ' pad=' + st.padding + ' inset=' + st.top + '/' + st.left +
               ' tf=' + (st.transform === 'none' ? 'none' : 'YES') +
               (e === c ? ' <<CONTAINER' : ''));
      if (e === document.documentElement) break;
      e = e.parentElement; i++;
    }
    post('CHAIN innerW=' + window.innerWidth + ' docClientW=' + document.documentElement.clientWidth +
         ' bodyClientW=' + document.body.clientWidth +
         ' htmlOverflow=' + getComputedStyle(document.documentElement).overflow +
         ' bodyOverflow=' + getComputedStyle(document.body).overflow +
         ' :: ' + out.join('  ||  '));
  }

  // ---- playback ---------------------------------------------------------------

  var wantMuted = true;
  var lastClick = 0;
  var panelActive = true;

  function noop() {}
  // WebKit rejects the first play() calls on this page with NotAllowedError even
  // though the reel is fully buffered - the app is an accessory that never becomes
  // active, so the page has no user activation. It does start accepting them a
  // moment later, so a rejection is retried tightly rather than left to the next
  // sweep: at the old 2500ms sweep interval a couple of rejections in a row left a
  // fully buffered video frozen for many seconds.
  var playRetry = null;

  function playQuiet(v) {                      // used for pre-warming; never retries
    try { var p = v.play(); if (p && p.catch) p.catch(noop); } catch (e) {}
  }

  function play(v) {
    try {
      var p = v.play();
      if (p && p.catch) p.catch(function (e) {
        if (e && e.name === 'NotAllowedError') retryPlay();
      });
    } catch (e) {}
  }

  // The reel that should be running. Falls back to whatever video is on screen
  // when the feed container has not mounted yet - during those first seconds the
  // enforcer used to return empty-handed and leave a fully buffered reel paused.
  function targetVideo() {
    var c = feedContainer();
    var list = c ? reels(c) : [];
    if (list.length) return list[activeIndex(list, c)].v;
    return activeVideo();
  }

  var PLAY = ['play', 'press to play', 'пусни', 'възпроизведи'];

  // The post view keeps its own playing/paused state and will re-pause the element
  // right after a bare play(). Drive its control instead so its state agrees.
  function clickPlayControl() {
    var v = activeVideo();
    if (!v || !v.paused) return false;
    var scope = v.closest('div[role="dialog"], article, section') || document;
    var btns = preferVisible(allLabeled(scope).filter(function (e) {
      return matchAny(labelOf(e), PLAY);
    }));
    if (btns) {
      var btn = btns;
      fire(btn);
      post('play: used Instagram play control (' + labelOf(btn) + ')');
      // It is a div, so it may well listen below click level. Escalate once, and
      // only while still paused, so this can never toggle a working video off.
      setTimeout(function () {
        var v2 = activeVideo();
        if (v2 && v2.paused) {
          firePointer(btn);
          post('play: control ignored click, sent pointer events');
          setTimeout(function () {
            var v3 = activeVideo();
            if (v3 && v3.paused) { firePointer(v3); post('play: pointer-tapped the video'); }
          }, 400);
        }
      }, 400);
      return true;
    }
    fire(v);                       // the post view toggles play on a tap
    post('play: tapped the video itself');
    return true;
  }

  function retryPlay() {
    if (playRetry) return;
    var tries = 0, t0 = performance.now();
    playRetry = setInterval(function () {
      tries++;
      if (!panelActive) { clearInterval(playRetry); playRetry = null; return; }
      var v = targetVideo();
      if (!v) { if (tries > 80) { clearInterval(playRetry); playRetry = null; } return; }
      if (!v.paused) {
        clearInterval(playRetry); playRetry = null;
        post('play: autoplay accepted after ' + tries + ' retries (' +
             Math.round(performance.now() - t0) + 'ms)');
        return;
      }
      v.muted = wantMuted;
      try { var p = v.play(); if (p && p.catch) p.catch(noop); } catch (e) {}
      // A handful of bare play() calls have got nowhere: the page is holding its own
      // paused state, so go through its UI once instead of retrying forever.
      if (tries === 6 || tries === 25) clickPlayControl();
      if (tries > 80) {
        clearInterval(playRetry); playRetry = null;
        post('play: still blocked after ' + tries + ' retries');
      }
    }, 120);
  }

  // Buffer and decode the following reel ahead of time by running it muted for a
  // moment and rewinding. Without this the first ~300ms after F9 is a frozen
  // first frame while WebKit fetches and starts the decoder.
  function warm(v) {
    if (!v || v.__rcWarm) return;
    v.preload = 'auto';
    if (v.readyState >= 3) { v.__rcWarm = true; return; }
    v.muted = true;
    v.__rcWarming = true;
    playQuiet(v);
    setTimeout(function () {
      try { v.pause(); v.currentTime = 0; } catch (e) {}
      v.__rcWarming = false;
      v.__rcWarm = true;
    }, 400);
  }

  // Resume the moment a reel pauses rather than waiting for the next poll - the
  // old 2.5s watchdog left a visibly frozen frame every time Instagram paused one.
  function hook(v) {
    if (v.__rcHooked) return;
    v.__rcHooked = true;
    v.addEventListener('pause', function () { setTimeout(function () { enforcePlayback(false); }, 30); });
    v.addEventListener('canplay', function () { setTimeout(function () { enforcePlayback(false); }, 0); });
    v.addEventListener('playing', function () {
      if (!window.__rcBooted) {
        window.__rcBooted = true;
        post('boot: first frame at ' + Math.round(performance.now() - T0) + 'ms after inject');
      }
    });
  }

  // Exactly one reel plays: the one on screen. Everything else is paused, which
  // keeps a feed of 20+ loaded videos from competing for decode time.
  // Pausing the off-screen reels fires their own 'pause' events, which call back
  // in here. Trailing debounce so that converges in one pass instead of a burst,
  // while still guaranteeing a final run (dropping calls would leave a reel frozen).
  var lastEnforce = 0, enforceTimer = null, playSince = 0;

  function enforcePlayback(force) {
    var now = Date.now();
    if (!force && now - lastEnforce < 60) {
      if (!enforceTimer) {
        enforceTimer = setTimeout(function () { enforceTimer = null; enforcePlayback(false); }, 80);
      }
      return;
    }
    lastEnforce = now;
    if (enforceTimer) { clearTimeout(enforceTimer); enforceTimer = null; }

    var c = feedContainer();
    if (!c) return;

    // Panel closed: keep everything stopped, including anything Instagram starts
    // on its own. Decoding video nobody can see is pure waste.
    if (!panelActive) {
      reels(c).forEach(function (o) { if (!o.v.paused) { try { o.v.pause(); } catch (e) {} } });
      return;
    }
    var list = reels(c);
    if (!list.length) return;
    // Which reel is playing must be decided by what is actually on screen, not by
    // cached tops. If the cache drifts, an index-based pick plays an off-screen reel
    // and pauses the visible one - which looks exactly like a freeze, with the video
    // sitting at readyState 4 and currentTime stuck.
    var onScreen = activeVideo();
    var ai = -1;
    if (onScreen) {
      for (var k = 0; k < list.length; k++) if (list[k].v === onScreen) { ai = k; break; }
    }
    if (ai < 0) ai = activeIndex(list, c);

    for (var i = 0; i < list.length; i++) {
      var v = list[i].v;
      hook(v);
      v.muted = wantMuted;
      if (i === ai) {
        // Respect a deliberate tap-to-pause for a few seconds; otherwise resume.
        if (v.paused && (force || Date.now() - lastClick > 4000)) {
          play(v);
          // A page that re-pauses without ever rejecting play() never trips the
          // NotAllowedError retry, so nothing would escalate. Give it a moment,
          // then go through its own Play control instead.
          if (!playSince) playSince = Date.now();
          else if (Date.now() - playSince > 1500) { playSince = 0; clickPlayControl(); }
        } else if (!v.paused) {
          playSince = 0;
        }
      } else if (!v.paused && !v.__rcWarming) {
        try { v.pause(); } catch (e) {}
      }
    }
    // Warm two ahead, not one: at a fast press rate the single lookahead has not
    // finished buffering before you are already past it.
    if (list[ai + 1]) warm(list[ai + 1].v);
    if (list[ai + 2]) warm(list[ai + 2].v);
  }

  function mute(on) {
    wantMuted = on;
    var c = feedContainer();
    var list = c ? reels(c) : [];
    list.forEach(function (o) { o.v.muted = on; });
    enforcePlayback(true);
    post('mute: ' + on);
  }

  function setActive(on) {
    panelActive = on;
    if (on) { enforcePlayback(true); post('panel: shown, playback resumed'); }
    else {
      var c = feedContainer();
      if (c) reels(c).forEach(function (o) { try { o.v.pause(); } catch (e) {} });
      post('panel: hidden, playback stopped');
    }
  }

  document.addEventListener('click', function () {
    if (!synthetic) lastClick = Date.now();
  }, true);

  document.addEventListener('playing', function () {
    if (!window.__rcBooted) {
      window.__rcBooted = true;
      post('boot: first frame at ' + Math.round(performance.now() - T0) + 'ms after inject');
    }
  }, true);

  // Boot probe: is a slow first reel the network, or us failing to start it?
  var probes = 0;
  var probeTimer = setInterval(function () {
    var c = feedContainer();
    var list = c ? reels(c) : [];
    var v = list.length ? list[activeIndex(list, c)].v : activeVideo();
    probes++;
    // Only speak up when the first reel is not running yet - a silent boot is a
    // healthy one, but a stall needs to say whether it is the network or us.
    if (probes >= 2 && !window.__rcBooted) {
      post('boot stalled ' + probes + 's: vis=' + document.visibilityState +
           ' hidden=' + document.hidden + ' focus=' + document.hasFocus() +
           ' activated=' + (navigator.userActivation ? navigator.userActivation.hasBeenActive : 'n/a') +
           ' container=' + !!c + ' reels=' + list.length +
           (v ? ' ready=' + v.readyState + ' paused=' + v.paused + ' net=' + v.networkState +
                ' buffered=' + (v.buffered.length ? v.buffered.end(0).toFixed(1) : 0)
              : ' video=none'));
      if (v && v.paused) retryPlay();
    }
    if (probes >= 12 || window.__rcBooted) clearInterval(probeTimer);
  }, 1000);

  // ---- scheduling ---------------------------------------------------------------
  // A MutationObserver instead of a fast interval: Instagram re-renders constantly,
  // but between renders there is nothing to do, and a 1s sweep was paying for DOM
  // queries and style writes forever - including during the initial hydration,
  // which is exactly when the page can least afford it.
  var sweepTimer = null;
  function sweep() {
    injectCSS();
    watchFeed();
    if (mode() === 'saved' && inSaved()) { openFirstSaved(); return; }
    if (isolate() + fillVideo()) invalidateReels();
    enforcePlayback(false);
    if (mode() === 'saved') return;      // post view: stripped above, no feed to top up
    var c = feedContainer();
    if (c && panelActive) topUp(c);
  }
  function scheduleSweep() {
    if (sweepTimer) return;
    sweepTimer = setTimeout(function () { sweepTimer = null; sweep(); }, 120);
  }

  function startWatching() {
    if (!document.body || window.__rcWatching) return;
    window.__rcWatching = true;
    new MutationObserver(scheduleSweep).observe(document.body, { childList: true, subtree: true });
  }

  // Tight cadence while the feed first mounts, then back off to a safety net.
  // Dedicated prefetch loop. Instagram serves roughly one page (5-7 reels) per
  // request and will not run two at once, so the only way to build a deep buffer
  // is to keep a request in flight as often as it will accept one. Riding the
  // 2.5s sweep was far too slow to outpace fast pressing.
  var lastBufLog = 0;
  setInterval(function () {
    if (!panelActive) return;
    var c = feedContainer();
    if (!c) return;
    var list = reels(c);
    if (!list.length) return;
    var ahead = list.length - 1 - activeIndex(list, c);
    if (ahead >= TARGET_AHEAD) return;
    nudgeLoader(c, c.scrollTop);
    if (Date.now() - lastBufLog > 5000) {
      lastBufLog = Date.now();
      post('buffer: ' + ahead + ' ahead of ' + list.length + ' loaded');
    }
  }, 400);

  startWatching(); sweep();          // do not wait 300ms for the first pass
  var boot = 0;
  var bootTimer = setInterval(function () {
    startWatching(); sweep();
    if (++boot > 60) { clearInterval(bootTimer); }   // ~12s
  }, 200);
  setInterval(function () { startWatching(); sweep(); }, 2500);

  return {
    next: next,
    save: save,
    dump: dump,
    chain: chain,
    like: like,
    toggleMode: toggleMode,
    recover: recover,
    health: health,
    active: setActive,
    mute: function (on) { wantMuted = on; mute(on); },
    clean: function (on) { cleanOn = on; if (on) { injectCSS(); isolate(); fillVideo(); } else restoreAll(); }
  };
})();
"""
