# Bezier: Arc parity roadmap

Status: ✅ done · 🟡 partial · ⬜ not started · ⛔ out of scope. Behaviour details for each area are in `references/release-notes/feature-timeline.md` and `references/arc-docs/`.

**Engine:** UI work runs on a WebKit development engine behind the `WebEngine` protocol. Chromium is next (`references/engine/chromium-embedding-options.md`), and features marked 🟡 below because of WebKit limits (extensions, DRM, real DevTools) land with it.

## Core UI

| Area | Status | Notes |
|---|---|---|
| Window chrome (theme frame, inset card, traffic lights in sidebar) | ✅ | Liquid Glass frame on macOS 26, blur fallback |
| Sidebar: URL pill, Favorites, pinned, folders, Today, footer | ✅ | Drag to reorder, pin or unpin, or drop into a folder; a tab's edges split, its middle groups |
| Hide sidebar (⌘S) and floating reveal from the left edge | ✅ | |
| Spaces: switch, theme crossfade, per-space last tab, two-finger swipe over the sidebar | ✅ | |
| Space theme editor (gradient pad, swatches, intensity, grain, glass), icon, rename, delete | ✅ | |
| Neutral themes (system/light/dark, accent colour), website appearance | ✅ | New Spaces default to neutral |
| Onboarding (Metal background, pen-tool Bézier wordmark, text transitions, turns into the browser) | ✅ | Help › Show Onboarding and Settings › General |
| Import from Arc (Spaces, pinned, folders, open tabs, Favorites, history, passwords) | ✅ | Settings › Import; also in onboarding |
| Passwords: autofill suggestions, save/update prompt, Settings › Passwords | ✅ | Encrypted (AES-GCM, key in the login keychain); password generation ⬜ |
| Profiles per Space (cookies and site data) | ✅ | Space menu › Profile, Settings › Spaces; history and passwords are shared |
| Command Bar (⌘T/⌘L): search, URLs, tabs, history, suggestions, ~60 actions, time zones, Tab to search a site | ✅ | 28 built-in sites |
| Tab Switcher (⌃Tab) | ✅ | Recent tabs with page thumbnails |
| Auto-archive, Archive, restore (⇧⌘T) | ✅ | |
| Tab groups (links opened by a page) | ✅ | Bezier addition, not in Arc; drag a tab out past the group's edge to leave it |
| Library (Archive, History, Downloads, Spaces) | ✅ | Media and Easels sections wait for those features |
| Settings (General, Spaces, Passwords, Shortcuts, Import, Advanced) | ✅ | Any menu shortcut can be changed |

## Power features

| Area | Status | Notes |
|---|---|---|
| Mini Bezier (Little Arc): links from other apps, ⌥⌘N, popups, dedupe, Open in Space | ✅ | Air Traffic Control rules in Settings › General |
| Developer Mode: auto for localhost/127.x, striped dev bar, ⌃D; JSON viewer | ✅ | |
| Capture (⇧⌘2: area, visible, full page) and Portrait Mode | ✅ | |
| Pinch zoom, page zoom | ✅ | |
| Downloads with progress | ✅ | |
| Split View (drag onto a tab's edge) | ✅ | 2–4 panes edge to edge, side by side or top to bottom, draggable dividers (saved) |
| Drag onto a tab's middle to group | ✅ | |
| Peek (links from pinned tabs and Favorites) | ✅ | Settings › General to turn off |
| Boosts: colours, font, Zap, custom CSS and JS (⌥⌘B) | ✅ | No Boosts list in the Library yet |
| Easels, Notes | ⬜ | Notes were removed from Arc in 2024 |
| Media controls, Mini Player, PiP | ✅ | Speaker icon mutes a tab; Mini Player in the sidebar; main frame only |
| Live Folders, calendar and hover previews | ⬜ | |
| Extensions (Chrome Web Store) | ⬜ | Needs Chromium |
| Find on page (⌘F, ⌘G, ⌘E) | ✅ | Match count covers the main frame only |
| Import from other browsers | ⬜ | |
| Ad-blocking | ⬜ | |
| Arc Max (AI) features | ⬜ | Decide scope |

## Out of scope

| Area | Status | Why |
|---|---|---|
| Accounts, sign-in, membership card, referrals | ⛔ | No account system (decided 2026-10-23) |
| Cloud Sync, share links for Spaces/Folders | ⛔ | They need a server account; CloudKit sync is a possible later option |
