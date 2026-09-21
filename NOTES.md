# Implementation notes

Several parts of this are deliberately counter-intuitive. Each one below is a
mistake that was made, measured, and corrected — please read before changing them.

## Hiding the chrome without breaking like/save

Two different hiding mechanisms, on purpose:

* **`display:none`** for page chrome outside the feed (top bar, bottom nav,
  sidebar) — it must not occupy space.
* **`visibility:hidden` + `position:absolute`** for the reel's own overlay: the
  author, caption, and the like/comment/share/save rail.

The overlay *is* the thing the shortcuts drive. `display:none` removes its layout
box, so the selectors — and therefore the like and save keys — stop finding it.
`visibility:hidden` keeps a real bounding box and the React click handlers, and
taking it out of flow stops the invisible rail shrinking the reel via flexbox.

Nothing keys off Instagram's class names; they are obfuscated and rotate. The
isolation walks the ancestor chain up from the `<video>` and hides everything off
that path.

A post view (saved mode) has no feed container, so it gets its own pass around the
single `<video>`. Stripping there can collapse a control's container to **0x0** —
the Next chevron is still perfectly clickable, so control lookups *prefer* a
control with a real box but accept a collapsed one. Requiring a visible box made
the next key dead in saved mode.

## Confirming a like or save

React unmounts the icon and mounts a **fresh node** when the state flips. Holding a
reference to the clicked element and re-reading its `aria-label` therefore always
reports failure — the detached original keeps its stale label forever. Re-query
instead, pinned to the rail that was actually clicked (`document.contains(rail)`),
never re-resolved by position, or a retry can act on a neighbouring reel.

Synthetic clicks are marked. Otherwise our own like/save clicks trip the `document`
listener that records the viewer's last tap, which suppresses auto-resume for four
seconds — the app was muting its own playback watchdog.

## Advancing

Scroll to the **exact top edge of the next card**, measured fresh, never
`scrollBy(clientHeight)`. A relative step compounds: one card that is not exactly
viewport-height desynchronises the feed permanently and you end up looking at two
half reels.

Instagram **recycles** the feed — it drops cards off the top as it appends to the
bottom — so `children.length` barely moves and a count-only cache check never
fires. The cached tops then point past the end of the scroll range, `scrollTop`
clamps, and every later press repeats the same impossible target forever. Guarded
three ways: a `MutationObserver` on the container's childList, a first/last-child
identity check, and — the backstop — reading `scrollTop` straight back after
assigning it, since a clamped value is immediate proof the target was unreachable.

`rebuildReels` counts only **in-flow** children. An out-of-flow child containing a
`<video>` contributes nothing to `scrollHeight` but still reports a bounding rect,
inventing a phantom reel far past the end — which made the health check declare a
working page wedged and reload it, throwing away the feed position.

The only synchronous work a press does is `scrollTop = goal` and `play()`, measured
at 0–2ms and flat whether the feed holds 8 reels or 44. Stripping, sizing and
playback bookkeeping all run *after* the new frame is on screen.

## Playback

Which reel plays is decided by **what is actually on screen** (rect nearest the
viewport centre), never by cached tops. A drifted cache makes the enforcer play an
off-screen reel and pause the visible one — indistinguishable from a freeze, with
the video still at `readyState 4` and `currentTime` stuck.

Playback is event-driven: a `pause` listener per video resumes within ~30ms. The
original 2.5s poll left a visibly frozen frame every time Instagram paused one.
Those pause calls re-enter, so the enforcer carries a **trailing debounce** — a
dropping throttle would leave a reel frozen.

WebKit rejects the first `play()` calls with `NotAllowedError`: the app is an
accessory that never becomes active, so the page has no user activation. A
rejection retries every 120ms rather than waiting for a sweep. Separately, a post
view **re-pauses the element without ever rejecting `play()`**, so that retry never
starts — a stubborn pause escalates to Instagram's own Play control, and from
`click()` to pointer events, since it is a `div` that ignores clicks.

The next two reels are pre-buffered (run muted briefly, then rewound) so the target
is normally at `readyState 4` before the key is pressed.

## Why there is no aggressive prefetching

Three approaches were built and measured. All of them trade against smoothness:

1. **Same-task scroll excursion** — set `scrollTop` to the bottom, fire the scroll
   event, set it back, all in one task so it is never painted. Completely invisible,
   and useless: the buffer plateaued at 8 reels for 30s. Instagram paginates from an
   IntersectionObserver, which only recomputes on a real rendering pass.
2. **Real excursion, masked** by pinning the playing video over the panel. Effective
   (2 → 21 reels loaded where the nudge stalled at 8) but the mask leaks: if any
   ancestor has a `transform` or `filter`, the pinned video's `position:fixed`
   resolves against *that* element instead of the viewport, and a reel visibly
   flashes past and snaps back.
3. **A five-screen-tall feed container** (cards stay one screen; `padding-bottom`
   keeps the last cards reachable). Invisible, geometry verified unchanged — and
   Instagram did load further ahead, but it then treats five reels as on screen and
   plays the *middle* one, pausing the reel being watched.

All three are reverted. Instagram serves roughly 5–7 reels per page and will not be
rushed without a visible side effect. What remains is the invisible nudge, and an
end-of-feed press that waits and fires itself once new reels land rather than being
dropped.

## Keyboard delivery

A Carbon hot key is global, but once the `WKWebView` takes keyboard focus a bare
F-key goes to the page instead. The panel therefore **cannot become key** while it
is the corner player (`canBecomeKey` returns false) — an AppKit guarantee, not a
heuristic — and is only allowed focus for the wide login window. A local `NSEvent`
monitor catches those keys anyway in that mode, and a 90ms dedupe window stops the
two paths double-firing one press.

Calls into the page are never written `window.__rc && window.__rc.f()`. If the
script threw on that page load, that expression is `undefined`: no error, no log,
every shortcut silently dead until a reload. Calls return a sentinel instead, and a
missing bridge is reinjected and the call retried.

## Testing

Synthesising keystrokes with `osascript ... key code` reaches global hot keys only
intermittently in a long session, while physical keys keep working — so a silent
synthetic press is a bad test, not a bug. Every action has a signal hook instead:

```
kill -USR1  dump every aria-label      kill -WINCH  next
kill -USR2  dump the layout chain      kill -INFO   like
kill -IO    open / close the panel     kill -URG    save
kill -HUP   start / stop the player    kill -PROF   saved mode
```
