# YTGlass: notes for Claude

Liquid Glass tweaks for YouTube 21.43.5 builds with YTPlus 6.0 (YTLite) and its Liquid Glass tab bar.
Maintainer: Michael Melita. See README.md for features and file layout.

## Working with Michael

- Keep replies short; don't explain how a fix works unless asked. Don't say "I haven't tested it on a phone".
- Deliver debug builds as an IPA in `~/Downloads/YTPlus_6.0_YTGlass_<version>.ipa` (see Build), deleting the previous debug IPA. Build a deb only when asked.
- When he says something doesn't work, strip the failed attempt completely before trying again. Keep the
  code clean: no dead code, no leftovers from failed attempts.
- When stuck on a bug, build a temporary on-screen diagnostic (a yellow label with live values and a log
  of changes with YouTube caller offsets), ask for a screen recording, then remove it again.
- For settings wording and new options, ask him (he edits the text himself).
- Workarounds for YTPlus bugs go in a file of their own, apart from YTGlass's own features, so they can be dropped
  when YTPlus fixes them (the YTPlus Fixes switch and `Sources/YTPlusFixes.m` were removed in 0.1.1).

## Versioning

- Released: 0.0.1 (first public release), 0.0.2 (pages opened on top of a tab keep YouTube's bar).
- Major feature release: +0.1 (0.1.0, 0.2.0, …). Small bug-fix release: +0.0.1 (0.0.3, or 0.1.1 after 0.1.0).
- Everything in between is a debug build: `Version: <next>~debugN` in `control` (e.g. `0.0.3~debug1`).
  No changelog entry, tag or release for debug builds.
- Only when Michael says to release: set the plain version, add one line to the README changelog,
  commit, tag `vX.Y.Z`, push, and create a GitHub release with `YTGlass.dylib` and the `.deb` attached
  (never the IPA: when he asks for one, build it straight to `~/Downloads/YTPlus_6.0_YTGlass_X.Y.Z.ipa` and never keep a copy in the repo;
  reuse the dylib already built for that version, `dist/YTGlass.dylib` or the release asset, instead of rebuilding).

## Build

Theos (rootless, arm64). Plain dylib, no CydiaSubstrate/ElleKit: hooks use `TBHHookMethod` in
`Sources/Common.h` (pure ObjC runtime swizzling).

The `ios-logos-tweak` skill (`.claude/skills/`) is for its general tweak advice only. Its Logos, Substrate and
`MSHookIvar` rules don't apply here: keep the plain runtime hooks so the dylib stays injectable into an IPA.

```sh
make clean && make package FINALPACKAGE=1 \
  ADDITIONAL_CFLAGS="-Wunused-const-variable -Wunused-parameter -Wunreachable-code-aggressive -Wunused-function"
```

The build must be warning-free. Delete old `.deb`s in `packages/` before each build (released ones are on GitHub). IPA: `bash Scripts/inject-ipa.sh stock/YTPlus_6.0_21.43.5.ipa dist/YTGlass.dylib ~/Downloads/YTPlus_6.0_YTGlass_X.Y.Z.ipa`
(the stock IPA is kept in `stock/`, which is gitignored; if it is missing, ask Michael to upload it).

## Settings

YouTube Settings → YTGlass, in the Tweaks group of PoomSmart's YouGroupSettings (bundled in YTPlus).
Category `'ytgl'`. NSUserDefaults keys: `YTGlass_SearchMode` (0 Off, 1 Separate, 2 Integrated),
`YTGlass_HideTopBar`, `YTGlass_PlayerGlass`. Hide-tab-bar-on-scroll is always on. Each feature reads its
switch at launch, so changes apply after a restart (the page's bottom row says so).

## YouTube internals learned (21.39.4; all hooked names still present in 21.43.5)

- Top bar: `YTHeaderView` inside `YTHeaderContentComboView` (`childView`, `_blurContainerView`,
  `headerView`). Collapse via `scrollHeaderViewWithOffset:`. A tab's pages can share one header
  (VC chain YTHeaderViewController > YTHeaderContentComboViewController > YTScrollableNavigationController),
  so "hide the bar" is decided per header and re-checked when a page is pushed (`THBAllowed`).
  Only a tab's first screen hides the bar; never search's own screen or the You tab (FElibrary/FEyou).
- Search results reuse the tab's header; the bar is shown while it holds the search box (a UITextField).
  `-[YTSearchResultsViewController optOutOfFrostedPivotBar]` is hooked to NO so results run under YTPlus's
  translucent tab bar.
- Page headers: `YTVariableHeightHeaderView`; `YTVariableHeightHeaderController -effectiveBaseTopContentInset`
  is lowered by the header height so Subscriptions/History start right under the title.
- Home feed: `YTAsyncCollectionView` (Texture cells). YouTube puts 8pt spacer cells above the first video,
  and their number changes between refreshes; the space is measured from visible cells and re-checked on
  list layout. After pull-to-refresh, `-[YTHeaderContentComboView resetScrollViewInsetOffset]` scrolls to
  content y 0; we put the offset back to our top.
- Tab identifiers: FEwhat_to_watch (Home), FEsubscriptions, FEhistory, FElibrary/FEyou, FEshorts.
  Tab labels (localised) come from the pivot item renderer's `title` (`stringWithFormattingRemoved`).
- Player glass: `+[YTFrostedGlassView liquidGlassEffect]` returns UIGlassEffect on iOS 26 when
  `-[YTColdConfig enableLiquidGlassEffect]` is YES (`liquidGlassEffectStyle` 1 regular, 2 clear). Every
  YTFrostedGlassView (play/pause, prev/next, fullscreen button, scrubber bubbles, miniplayer controls)
  then uses real glass. Other "frosted glass" cold-config flags are not read anywhere in this version.
  Top-row player buttons get a 40pt YTFrostedGlassView circle (larger sizes were clipped; reverted).
- YTPlus's tab bar is a system `UITabBar` inside `YTPivotBarView`; the separate search button narrows it,
  the integrated mode appends a UITabBarItem and wraps the delegate's `tabBar:didSelectItem:`.
- Player top right: YTPlus's second row (mute, sleep timer, menu) is a UIStackView of YTQTMButtons labelled `YTL...`
  in `YTMainAppControlsOverlayView`; the top row is a small UIView holding YouQuality's quality label and the settings
  button (`id.player.overflow.button`). YouTube fades each button on its own (not their containers), so shared glass
  lives inside the settings button.
- Player bottom right: `YTInlinePlayerBarContainerView` holds `YTWatchPlayerControlsRightIcons` >
  `YTEnterExitFullscreenButtonView` and (portrait) YouQuality's button directly, or (full screen) in a small wrapper
  elsewhere. YouTube/YouQuality keep re-setting those frames, so moving one with a transform flickers; `PlayerGlass.m`
  shifts it through a per-instance subclass of its frame/center accessors instead.

## Planned

- Liquid Glass tab bar: parked again after 0.1.2. Attempts on branches: `wip/native-tab-bar` (iOS's own tab bar, a
  UITabBarController with UITabs inside YouTube's bar; hold Home didn't work on it and Search: Separate sat inside
  the bar) and `wip/glass-tab-bar` (hand-built with YTKACE's lens; felt laggy, icons jumped). Michael tried YTKACE's own
  bar and didn't like it. He wants native iOS behaviour, not imitations. Independent of YTPlus: never touch it.
- 0.1.1 is 0.0.6 plus the mini player fix (it follows the tab bar, TabBarAutoHide.m), because 0.1.0 made Home's
  scrolling slower; 0.1.0's DeArrow, AiSList, Off/Integrated tab bar unclipping and the Slide Up animation rename
  are not in it.

## YouTube 21.43.5 / YTPlus 6.0 differences

- Home's tab button (YTPivotBarItemView) has no renderer, so no identifier or title: it's recognised as the first
  button (`TBHItemIdentifier`). YouTube's tabs have no labels at all; `YTPlusTabLabels.m` names YTPlus's tabs in English.
- YTPlus places its UITabBar without `-setFrame:`; the separate search button narrows it on YTPivotBarView layout.
- YTPlus's tabs have no titles, so Hold Home goes by the first tab's position.
- `+[YTFrostedGlassView liquidGlassEffect]` just returns nil: PlayerGlass puts a UIGlassEffect (capsule) on each
  YTFrostedGlassView's `blurEffectView` itself and hides its `overlayView`.
- The player's quality label is empty until YouQuality fills it in (YouQuality/YTVideoOverlay, not ours).
- Diagnostics: logs written to a file in YouTube's Documents and copied off with
  `xcrun devicectl device copy from --domain-type appDataContainer` are more reliable than idevicesyslog.
