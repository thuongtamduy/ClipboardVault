# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

ClipboardVault — a SwiftUI macOS clipboard-history app (menubar + main window). Swift 6 toolchain, targets macOS 13+. The README is written in Vietnamese; user-facing copy in `Sources/main.swift` is also Vietnamese.

## Commands

- `swift run` — build and run the executable directly (will not be a proper `.app` bundle; menubar/launch-at-login features behave best when run from a bundle in `/Applications`).
- `./build_app.sh` — `swift build` + assemble `ClipboardVault.app/` with `Info.plist` (`LSUIElement=true`) and icon. Outputs `ClipboardVault.app` in repo root, using the **debug** binary from `.build/debug/ClipboardVault`. Edit the script if you need a release build.
- `./create_icns.sh` — regenerate `app_icon.icns` from `app_icon.png` via `sips` + `iconutil`.
- `open Package.swift` — open in Xcode.

There are no tests.

## Architecture

The entire app lives in one file: `Sources/main.swift` (~900 lines). The pieces below describe the cross-cutting design that isn't obvious from a single glance.

### Two SwiftUI scenes, one shared store
`ClipboardVaultApp` declares both a `WindowGroup` (full UI: `ContentView` → `SidebarView` + `MainPanelView`) and a `MenuBarExtra` (compact `QuickPanelView`). Both bind to the **same** `@StateObject ClipboardStore`. Any change to clipboard state must go through `ClipboardStore` so both surfaces stay in sync. On launch the app sets `NSApplication.shared.setActivationPolicy(.accessory)` — it's a menubar app, not a dock app.

### Capture loop
`ClipboardStore` polls `NSPasteboard.general.changeCount` every **0.5 s** via a `Timer`. Deduplication uses a `lastSignature` string (`"text:<value>"` or `"image:<hashValue>"`) — if you change the dedup key, both the text and image branches in `checkClipboard()` must agree. Max history is **200 entries** (`maxEntries`); both the in-memory array and SQLite are trimmed together.

### Persistence (SQLite, raw C API)
`ClipboardPersistence` opens `~/Library/Application Support/ClipboardVault/clipboard.sqlite` with `PRAGMA journal_mode=WAL`. The single `clipboard_entries` table stores text in `text_value` and images as TIFF BLOBs in `image_data`. Image bytes are loaded lazily by `loadImageData(id:)` from `EntryCard` so large images don't sit in memory. `SQLITE_TRANSIENT` is hand-defined at the top of the file because the Swift `SQLite3` module doesn't export it. `createTableIfNeeded` runs idempotent `ALTER TABLE ADD COLUMN` calls to migrate older DBs that predate `image_width`/`image_height`; preserve this pattern when adding new columns.

### Global hotkey
`GlobalHotKeyManager` registers `Cmd+Shift+V` via the **Carbon** `RegisterEventHotKey` API (not SwiftUI keyboard shortcuts). The Carbon callback bridges back to Swift via `Unmanaged.passUnretained(self)`. On trigger it activates the app and brings the main window forward (or opens it via `openWindow(id: "main")` if not present). Window lookup is by title `"ClipboardVault"` — keep that title stable.

### Launch at login + Applications-folder requirement
`LaunchAtLoginManager` uses `SMAppService.mainApp`, which requires the app to be running from `/Applications`. `AppInstaller` detects when the app is running from elsewhere and exposes `moveToApplications()`; `MainPanelView` shows a yellow prompt banner when `isBundle() && !isRunningFromApplications()`. After moving, the running instance terminates and the moved copy launches.

### Smart text rendering
`ClipboardEntry.smartType` classifies text entries as `.url`, `.color` (6-digit `#RRGGBB`), or `.none`. `EntryCard` branches on this to render colour swatches, link icons, or generic text. If you add a new smart type, both `smartType` and `EntryCard`'s switch must be updated.

### Filtering and sorting
`filteredEntries` is the single source of truth for what the main list shows: favourites first, then newest-first, then filtered by sidebar selection (`all`/`text`/`images`/`favorites`), then filtered by `searchText`. Toolbar `Cmd+1..4` switches the sidebar filter. `quickEntries` (used by the menubar panel) ignores filters and just returns the 20 most recent.

## Conventions

- All UI-affecting state mutation must happen on `@MainActor`. `ClipboardStore` and `LaunchAtLoginManager` are both `@MainActor`-isolated; the polling `Timer` hops back via `Task { @MainActor in … }`.
- SQL identifier comparisons use `LOWER(id) = LOWER(?)` so UUID casing differences don't cause misses — match this when adding new lookups.
- Don't introduce SwiftPM dependencies casually: the package currently has zero external dependencies and links only the system `sqlite3` library (declared via `linkerSettings` in `Package.swift`).
