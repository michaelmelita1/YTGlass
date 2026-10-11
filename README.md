# YTGlass

Liquid Glass tweaks for YouTube builds with **YTPlus 6.0** and its Liquid Glass tab bar. Everything is on by default; each feature can be switched off on the YTGlass page in YouTube's settings.

## What it does

- **Tab bar hides on scroll**, on every page (YouTube itself only does this on Home). Scrolling down about 64pt
  hides it; scrolling up about 25pt, reaching the top or switching tabs brings it back. A fling is projected
  forward. Never on Shorts. Works on nested-scroll pages like History.
- **Round glass search button** to the right of the tab bar, like Apple Music and the App Store on iOS 26.
  It matches the capsule's height, hides and shows with the bar, and opens YouTube's normal search.
- **No top bar**: YouTube's top navigation bar is removed on every page except search and the You tab.
  Pages scroll behind the status bar under a variable blur with a light tint, like Apple Music.
- **Large titles**: Home, Subscriptions and History get an Apple Music-style title that scrolls with the page.
  Subscriptions' avatars/chips and History's title/search box/chips are removed.
- **Liquid Glass player controls**: YouTube's own Liquid Glass (clear style) behind play/pause and previous/next, and a 40pt glass circle behind each top-row player button (captions, settings, cast, and buttons other tweaks add there).
- **No slide-up animation** when switching tabs: the new tab's page appears straight away.
- **Even spacing on Home**: Home's blank spacer rows (YouTube's own, and the ones YTPlus's ad blocking leaves
  behind) are collapsed, so its videos are spaced like Subscriptions'.
- **Settings in YTPlus's tab bar menu**: a Settings item opens YouTube's settings from any tab.
- **YTPlus fixes**: workarounds for YTPlus bugs, kept separate so they can go once YTPlus fixes them. Currently:
  the settings close button, which YTPlus's Liquid Glass leaves with no width (drawn over the title, untappable).

## Settings

YouTube Settings → YTGlass (in the Tweaks group when YouGroupSettings is installed, as in YTPlus builds;
otherwise right after General). One setting per feature, all on by default; changes apply after restarting
YouTube:

- **Search**: Off, Separate (a round glass button next to the tab bar, the default) or Integrated (a Search
  item at the end of YTPlus's tab bar)
- **Hide Navigation bar** (the top bar, with the status bar blur and large titles)
- **Liquid Glass player**
- **YT Slide Up Animation** (on: the animation is disabled)
- **YTPlus Fixes**

Hiding the tab bar on scroll, Home's spacing and the Settings menu item are always on.

## How

- `Sources/TabBarAutoHide.m`: hides the bar with YouTube's own `-[YTAppView hidePivotBar]` / `-showPivotBar`
  (what Home uses), so the feed's bottom inset and the mini-player follow. Scroll tracking ported from
  [YTKACE](https://github.com/itzzace/ytkace) v1.1.1 (MIT).
- `Sources/SearchButton.m`: narrows YTPlus's `UITabBar` and adds the button inside `YTPivotBarView`. Tapping it
  taps the hidden top bar's `id.ui.navigation.search.button`.
- `Sources/HideTopBar.m`: keeps `YTHeaderView` collapsed with YouTube's own `scrollHeaderViewWithOffset:` and
  invisible; detaches the page headers in `YTVariableHeightHeaderView`; sets each page list's top inset and adds
  the title; draws the blur, ported from [BlurUIKit](https://github.com/TimOliver/BlurUIKit)'s
  `VariableBlurView` (MIT, Tim Oliver).
- `Sources/PlayerGlass.m`: turns on YouTube's `enableLiquidGlassEffect` flag (style 2, clear) so its `YTFrostedGlassView`s use iOS 26 glass, and adds a `YTFrostedGlassView` circle inside each top-row `YTQTMButton` of `YTMainAppControlsOverlayView`.
- `Sources/TabAnimation.m`: turns off YouTube's `+[YTModernTransitions isTabSlideUpAnimationEnabled]` flag.
- `Sources/HomeSpacing.m`: after Home's `YTTopAlignGridCollectionViewLayout` lays out, its 8pt `ELMCellNode` spacer
  rows get no height and the rows below move up (the rows' own sizes are left alone).
- `Sources/MenuSettings.m`: adds the Settings item to YTPlus's menu (recognised by its translated Tab bar item) and
  sends YouTube's `+[YTICommand applicationSettingsNavigationEndpoint]` command.
- `Sources/YTPlusFixes.m`: workarounds for YTPlus bugs; the settings close button (`id.ui.browse.close.button`)
  gets a square size when it has none.
- `Sources/Settings.m`: the settings page (YouTube's own settings framework: a `'ytgl'` category added to `+[YTAppSettingsPresentationData settingsCategoryOrder]` and to YouGroupSettings' `+[YTSettingsGroupData tweaks]`, filled in `-[YTSettingsSectionItemManager updateSectionForCategory:withEntry:]`). Switches are stored in `NSUserDefaults` (`YTGlass_*` keys) and read by each feature at launch.
- `Sources/Common.h`: the shared runtime hook helper and the functions the files share.

Pure Objective-C runtime swizzling, no CydiaSubstrate/ElleKit dependency. See `LICENSE` for both MIT notices.

## Changelog

- **0.0.5**: no slide-up animation when switching tabs (YT Slide Up Animation switch); Home's videos spaced like Subscriptions'; YTPlus Settings Fix renamed YTPlus Fixes; smoother scrolling.
- **0.0.4**: a Settings item in YTPlus's tab bar menu opens YouTube's settings from any tab; new YTPlus Settings Fix switch makes the settings close button tappable again with YTPlus's Liquid Glass.
- **0.0.3**: the YTGlass settings page shows the installed version at the bottom; code cleanup.
- **0.0.2**: pages opened on top of a tab (channels, playlists, …) keep YouTube's navigation bar, with their back button and header; fixes channel pages losing their header and, on iPad, not responding to touches.
- **0.0.1**: first public release.

## Use

Inject `YTGlass.dylib` into a decrypted YouTube IPA (Sideloadly / Feather / ESign / cyan, or
`bash Scripts/inject-ipa.sh YouTube.ipa dist/YTGlass.dylib out.ipa`), then sign and install as usual.
Rootless `.deb` for jailbroken devices.

## Build

```sh
make package FINALPACKAGE=1
```
