# YTGlass

Liquid Glass tweaks for YouTube builds with **YTPlus 6.0** and its Liquid Glass tab bar. Everything is on by default; each feature can be switched off on the YTGlass page in YouTube's settings.

## What it does

- **Tab bar hides on scroll**, on every page (YouTube itself only does this on Home). Scrolling down about 64pt
  hides it; scrolling up about 25pt, reaching the top or switching tabs brings it back. A fling is projected
  forward. Never on Shorts. Works on nested-scroll pages like History.
- **Round glass search button** to the right of the tab bar, like Apple Music and the App Store on iOS 26.
  It matches the capsule's height, hides and shows with the bar, and opens YouTube's normal search.
- **No top bar**: YouTube's top navigation bar is removed on every page except search and the You tab.
  Pages scroll behind the status bar under iOS's own soft scroll edge.
- **Large titles**: Home, Subscriptions, History and Watch later get an Apple Music-style title that scrolls with the page.
  Subscriptions' avatars/chips and History's title/search box/chips are removed.
- **Liquid Glass player controls**: YouTube's own Liquid Glass (clear style) behind play/pause and previous/next, and a 40pt glass circle behind each top-row player button (captions, settings, cast, and buttons other tweaks add there).
  YTPlus's second row of player buttons moves up beside settings, the group sharing one glass capsule; at the
  bottom, YouQuality's label and the full screen button share one pill.
- **No slide-up animation** when switching tabs: the new tab's page appears straight away.
- **Even spacing on Home**: Home's blank spacer rows (YouTube's own, and the ones YTPlus's ad blocking leaves
  behind) are collapsed, so its videos are spaced like Subscriptions'.
- **Liquid Glass Tab Bar**: iOS 26's own tab bar in place of YouTube's and YTPlus's, with YouTube's icons and Search as
  iOS's glass circle beside it. Holding Home opens YouTube's settings, and the mini player moves with the bar.
- **Native Glass Menu**: a long press on a video, or its ⋯ button, opens iOS's own menu with YouTube's items (and
  YTPlus's), right at the finger or the ⋯. The ⋯ below the player, whose sheet can't be an iOS menu, is hidden.
- **DeArrow** (off by default): replaces video titles and/or thumbnails in feeds with [DeArrow](https://dearrow.ajay.app)'s
  community ones.
- **Hide AI channels** (off by default): removes channels on the [AiSList](https://aisloplist.com) blocklist and/or
  warnlist from feeds and search.
- **Search**: Off, Separate (a round glass button next to the tab bar, the default) or Integrated (a Search
  item at the end of YTPlus's tab bar)
- **Hide Navigation bar** (the top bar, with the status bar blur and large titles)
- **Liquid Glass player**
- **Liquid Glass Tab Bar**
- **Slide Up animation** (on: the animation is disabled)
- **DeArrow titles**, **DeArrow thumbnails**, **Hide AI channels**, **Hide suspected AI channels** (off by default; they go online)

Hiding the tab bar on scroll and Home's spacing are always on.

## How

- `Sources/TabBarAutoHide.m`: hides the bar with YouTube's own `-[YTAppView hidePivotBar]` / `-showPivotBar`
  (what Home uses), so the feed's bottom inset and the mini-player follow. Scroll tracking ported from
  [YTKACE](https://github.com/itzzace/ytkace) v1.1.1 (MIT).
- `Sources/SearchButton.m`: narrows YTPlus's `UITabBar` and adds the button inside `YTPivotBarView`. Tapping it
  taps the hidden top bar's `id.ui.navigation.search.button`.
- `Sources/HideTopBar.m`: keeps `YTHeaderView` collapsed with YouTube's own `scrollHeaderViewWithOffset:` and
  invisible; detaches the page headers in `YTVariableHeightHeaderView`; sets each page list's top inset and adds
  the title; gives the list iOS's soft top scroll edge (`UIScrollEdgeEffectStyle.softStyle`).
- `Sources/PlayerGlass.m`: turns on YouTube's `enableLiquidGlassEffect` flag (style 2, clear) so its `YTFrostedGlassView`s use iOS 26 glass, and adds a `YTFrostedGlassView` circle inside each top-row `YTQTMButton` of `YTMainAppControlsOverlayView`.
- `Sources/TabAnimation.m`: turns off YouTube's `+[YTModernTransitions isTabSlideUpAnimationEnabled]` flag.
- `Sources/HomeSpacing.m`: after Home's `YTTopAlignGridCollectionViewLayout` lays out, its 8pt `ELMCellNode` spacer
  rows get no height and the rows below move up (the rows' own sizes are left alone).
- `Sources/SystemTabBar.m`: a `UITabBarController` of YTGlass's over `YTAppView` (empty, see-through pages; only the
  bar takes touches), with YTPlus's tab items and iOS 27's `prominentTabIdentifier` for the search circle. Choosing a
  tab chooses it on YTPlus's bar; it hides with `YTPivotBarView`. Holding Home sends YouTube's
  `+[YTICommand applicationSettingsNavigationEndpoint]`.
- `Sources/NativeMenus.m`: when YouTube's `YTDefaultSheetController` presents a video's menu during a long press or
  from a ⋯ (`forcedSheetStyle` 1), its `YTActionSheetAction`s (title and icon from each action's button) become a
  `UIMenu`, opened at the finger with `UIContextMenuInteraction`'s `_presentMenuAtLocation:` in a small window of its
  own; the picked action's handler runs once the menu has closed. Hides the last button of
  `id.video.non_scrollable_action_bar` (the ⋯ below the player).
- `Sources/DeArrow.m`: ported from YTKACE v1.1.3; reads the video ID from each feed thumbnail's URL
  (`ELMImageNode`), asks DeArrow's branding API, sets the DeArrow thumbnail on the node and the title on the card's
  title `ELMTextNode`. Results are cached; requests are limited to 4 at once and 90 a minute.
- `Sources/AiSList.m`: ported from YTKACE v1.1.3; downloads the AiSList lists every 4 hours and leaves out feed
  sections (`YTInnerTubeCollectionViewController`) whose data names a listed channel handle or ID.
- `Sources/Settings.m`: the settings page (YouTube's own settings framework: a `'ytgl'` category added to `+[YTAppSettingsPresentationData settingsCategoryOrder]` and to YouGroupSettings' `+[YTSettingsGroupData tweaks]`, filled in `-[YTSettingsSectionItemManager updateSectionForCategory:withEntry:]`). Switches are stored in `NSUserDefaults` (`YTGlass_*` keys) and read by each feature at launch.
- `Sources/Common.h`: the shared runtime hook helper and the functions the files share.

Pure Objective-C runtime swizzling, no CydiaSubstrate/ElleKit dependency. See `LICENSE` for the MIT notices and the DeArrow and AiSList data licenses.

## Changelog

- **0.2.4**: Native Glass Menu: iOS's own menu for a long press on a video and its ⋯ button (with YouTube's and YTPlus's items); the ⋯ below the player is hidden.
- **0.2.3**: Hide Navigation bar uses iOS's own soft scroll edge under the status bar instead of a hand-made blur.
- **0.2.2**: the tab bar no longer comes up over the video page when the list under a video is scrolled; Hide Navigation bar leaves the page alone in full screen landscape (it could get into a layout loop with YouTube behind the player, making it lag).
- **0.2.1**: for YTPlus 6.0 and YouTube 21.43.5; new Liquid Glass Tab Bar switch: iOS's own tab bar with YouTube's icons, every YTPlus tab and Search as a glass circle beside it, with Hold Home for settings and the mini player fix (the old Hold Home switch is replaced); Hide Home tabs (the Subscriptions, Music and Live tabs at the top of Home); large title on Watch later; the Liquid Glass player works again on 21.43.5; YTPlus's tabs get their labels back; Home's title and spacing found from the page itself.
- **0.1.2**: holding the Home tab opens YouTube's settings instead of YTPlus's tab bar menu (Hold Home for settings switch); the Settings item in that menu is removed.
- **0.1.1**: built on 0.0.6 for Home's smooth scrolling; the mini player moves with the tab bar on every page, with the bar's own animation; the tab bar stays hidden when a list bounces at its end; DeArrow and AiSList back, lighter while scrolling; Slide Up animation renamed; YTPlus Fixes removed (YTPlus fixed the bug); smaller optimisations.
- **0.0.6**: YTPlus's player buttons (mute, sleep timer, menu) move into the top row and share one glass capsule with settings; the quality label and full screen button share one pill at the bottom; faster tab bar handling (Shorts checks skipped when there's no Shorts tab).
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
