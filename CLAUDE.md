# YTGlass: notes for Claude

Liquid Glass tweaks for YouTube 21.39.4 builds with YTPlus 6.0 b2 (YTLite) and its Liquid Glass tab bar.
Maintainer: Michael Melita. See README.md for features and file layout.

## Working with Michael

- Keep replies short; don't explain how a fix works unless asked. Don't say "I haven't tested it on a phone".
- Deliver the dylib (`dist/YTGlass.dylib`) for testing. Build a deb or IPA only when asked.
- When he says something doesn't work, strip the failed attempt completely before trying again. Keep the
  code clean: no dead code, no leftovers from failed attempts.
- When stuck on a bug, build a temporary on-screen diagnostic (a yellow label with live values and a log
  of changes with YouTube caller offsets), ask for a screen recording, then remove it again.
- For settings wording and new options, ask him (he edits the text himself).
- Workarounds for YTPlus bugs all go in `Sources/YTPlusFixes.m` (behind the YTPlus Fixes switch,
  key `YTGlass_YTPlusSettingsFix`, named before the rename), kept apart from YTGlass's own features so they can be dropped when YTPlus fixes them.

## Versioning

- Released: 0.0.1 (first public release), 0.0.2 (pages opened on top of a tab keep YouTube's bar).
- Major feature release: +0.1 (0.1.0, 0.2.0, …). Small bug-fix release: +0.0.1 (0.0.3, or 0.1.1 after 0.1.0).
- Everything in between is a debug build: `Version: <next>~debugN` in `control` (e.g. `0.0.3~debug1`).
  No changelog entry, tag or release for debug builds.
- Only when Michael says to release: set the plain version, add one line to the README changelog,
  commit, tag `vX.Y.Z`, push, and create a GitHub release with `YTGlass.dylib` and the `.deb` attached
  (never the IPA: when he asks for one, build it straight to `~/Downloads/YTPlus_6.0b2_YTGlass_X.Y.Z.ipa` and never keep a copy in the repo;
  reuse the dylib already built for that version, `dist/YTGlass.dylib` or the release asset, instead of rebuilding).

## Build

Theos (rootless, arm64). Plain dylib, no CydiaSubstrate/ElleKit: hooks use `TBHHookMethod` in
`Sources/Common.h` (pure ObjC runtime swizzling).

```sh
make clean && make package FINALPACKAGE=1 \
  ADDITIONAL_CFLAGS="-Wunused-const-variable -Wunused-parameter -Wunreachable-code-aggressive -Wunused-function"
```

The build must be warning-free. Delete old `.deb`s in `packages/` before each build (released ones are on GitHub). IPA: `bash Scripts/inject-ipa.sh "stock/YTPlus 6.0b2 21.39.4.ipa" dist/YTGlass.dylib ~/Downloads/YTPlus_6.0b2_YTGlass_X.Y.Z.ipa`
(the stock IPA is kept in `stock/`, which is gitignored; if it is missing, ask Michael to upload it).

## Settings

YouTube Settings → YTGlass, in the Tweaks group of PoomSmart's YouGroupSettings (bundled in YTPlus).
Category `'ytgl'`. NSUserDefaults keys: `YTGlass_SearchMode` (0 Off, 1 Separate, 2 Integrated),
`YTGlass_HideTopBar`, `YTGlass_PlayerGlass`. Hide-tab-bar-on-scroll is always on. Each feature reads its
switch at launch, so changes apply after a restart (the page's bottom row says so).

## YouTube internals learned (21.39.4)

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

- Replacement Liquid Glass tab bar (WIP, branch `wip/glass-tab-bar`): our own glass capsule on YouTube's `YTPivotBarView`
  (independent of YTPlus, never touching it; YTPlus's Liquid Glass tab bar is switched off by hand), ported from
  YTKACE's TabBarHooks.mm with iOS's `_UILiquidLensView`, and the search button in the same `UIGlassContainerEffect`
  so it merges when the capsule is stretched into it (like the iOS 26 Phone app); Integrated mode as a Search slot.
  Shelved at 0.1.1~debug16: not working well yet (touch response, mini player, a band across the bottom).
