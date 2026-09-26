# Mac Vitals

A native macOS system monitor and cleaner: Activity Monitor–style vitals, CleanMyMac–style cleanup,
and a single health score that tells you whether your Mac is okay.

SwiftUI + Liquid Glass, macOS 26+, Apple silicon and Intel. Not sandboxed (process inspection and
cleanup need it), so it ships via Developer ID + notarization rather than the Mac App Store.

## Build & run

```bash
brew install xcodegen      # once
xcodegen generate          # regenerate MacVitals.xcodeproj after adding/removing files
open MacVitals.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project MacVitals.xcodeproj -scheme MacVitals -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/MacVitals.app
```

Tests (Swift Testing): `xcodebuild test -project MacVitals.xcodeproj -scheme MacVitals -destination 'platform=macOS,arch=arm64'`

## Layout

```
MacVitals/
  App/            entry point, navigation, settings keys
  Core/
    Samplers/     CPU, memory, disk, network, battery, processes (Mach/IOKit/libproc)
    Health.swift  health score + vital-signs checklist (pure, unit-tested)
    SystemMonitor sampling loop, history, visibility-aware publishing
    Cleanup/      cleanup scanner + model
    Protection/   built-in defences, startup-item and app signature audits
    SpaceLens/    getattrlistbulk size scanner, sunburst layout
    Updates/      Sparkle appcasts, App Store lookup, Homebrew, verified installer
    Duplicates/   exact duplicate finder (size → ends → SHA-256), clone-aware space, keep rules;
                  similar photos (Vision), screenshots, PhotoKit access
    Notifications/ alert rules (AlertPolicy: persistence, cooldown, escalation, hourly cap) + delivery
    Ports/        listening-port / dev-server scanner
  Views/
    Components/   glass cards, tile visuals, charts, visibility tracking
    Sections/     one file per dashboard section
    MenuBarViews  status-item icon + panel
MacVitalsTests/
```

## Menu bar vs. main window

- **Menu bar icon**: static glyph. Orange dot = warning, red dot = critical. Info-level items don't badge.
- **Panel**: answers "is my Mac okay, and if not, what's the one thing to do?" Health score, up to three
  actionable issues with fix buttons, four mini gauges, top 3 apps (inline quit), Clean Up / Dev Servers shortcuts.
  No charts, no scrolling.
- **Main window**: investigate and manage. History charts, full apps table, cleanup review, dev servers.

## Permissions

All optional; the app works without any. First launch shows a welcome screen that explains each one by
what it unlocks; Settings › Permissions shows live status. Pages also ask in context, exactly where
something is missing.

| Permission | Unlocks | How it's granted / detected |
|---|---|---|
| Full Disk Access | Trash, Mail/Messages, iPhone backups, app containers in Storage & Clean Up | Settings list + floating drag helper; detected by probing a protected file |
| Location | Wi-Fi network name on the Network page (macOS treats it as location) | System prompt; never requests a location |
| App Management | Uninstaller moving apps to the Trash | Settings list + helper with a Done button. macOS offers no way to check it (its record stays locked even with Full Disk Access), so status comes from the last real uninstall, and a blocked uninstall offers the fix |
| Automation › Finder | Removing items installed for all users (Finder asks for the admin password) | System prompt via `AEDeterminePermissionToAutomateTarget` |

Blocked removals are classified by what fixes them (`RemovalBlocker`: EPERM on an app → App Management,
EPERM elsewhere → Full Disk Access, EACCES → admin via Finder), and the result banner offers that one fix.

**Startup items never prompt on their own.** macOS's complete list (`sfltool dumpbtm`) now needs an
admin password, and running it directly shows a system prompt titled "sfltool" that looks like malware.
The default scan uses launchd folders plus active helpers inside installed apps; "Show Complete List…"
reads the full list once per session through Mac Vitals' own prompt (`BTMAccess`).

**Signing matters:** macOS remembers these permissions by code signature. Builds are signed with a stable
Developer ID (`project.yml`); ad-hoc signing made every rebuild look like a new app and silently dropped
them. Release omits `get-task-allow` so it can be notarized.

## Notifications

Settings › Notifications: disk almost full, memory critical, running hot, apps stuck or leaking
(with a Quit button), battery service, a protection switched off, critical app updates, and an
opt-in weekly update digest. Rules live in `AlertPolicy` (pure, unit-tested): a condition must last
(e.g. 3 min for memory), won't repeat within its cooldown unless it gets worse, is never sent while a
Mac Vitals window is on screen, and at most 3 go out per hour. The monitor feeds it from the
background loop (throttled to every 30 s; background CPU unchanged at ~0.2%); protections are
re-checked every 6 h and updates daily.

## Performance rules (measured, Release build, M1 Pro)

| State | CPU (% of one core) |
|---|---|
| Menu bar only (window closed) | ~0.2% |
| Any dashboard page visible, 2s refresh | ~1–9% |

Measure with `scripts/rebuild.sh && scripts/perf.sh <section> [seconds]` (it verifies the window stayed
frontmost; occluded windows go idle by design). Section names match `DashboardSection` (cpu, memory, …).

Things that looked harmless and weren't:

1. **No SwiftUI animations on values that change every refresh.** While any SwiftUI animation is in
   flight, SwiftUI recomputes the view every display frame (up to 120 fps), in-process. Bars, rings and
   rolling numbers animating every 2s cost the CPU page 51% of a core. Now:
   - bars/rings/stacked bars use Core Animation (`LayerBar`, `LayerRing`/`GaugeRing`, `LayerSegments`),
     which glides in the render server with no per-frame work in our process
   - rolling digits use `RollingText` (Core Animation, one layer per character; only changed digits roll).
     SwiftUI's `.numericText()` on one hero number measured +10–17% per page. Roll the one number per page
     people watch; supporting stats update crisply (`DetailStat(rolls:)` is opt-in)
   - list animations key on *status* (e.g. check severity), not on live text
2. **Never wrap sample updates in a global `withAnimation`** (51% → 15% when removed).
3. **No continuously animating views behind glass.** Motion is event-driven only.
4. **Don't publish when nobody is looking.** `SystemMonitor` records into private storage and only
   publishes while a window reports itself visible (`VisibilityTracker`).
5. **Pre-render app icons to small bitmaps**; full icons were resampled on the CPU every refresh.
6. rusage CPU times are **Mach ticks**, not nanoseconds (×125/3 on Apple silicon).

Charts, Liquid Glass and large lists measured as cheap; animation was the cost.

## Known gaps / next

- SSD wear level and total data written (Disk › Under the hood)
- Clean Up extras: duplicates, a small honest maintenance set, Mail attachments
- Privileged helper for root-owned processes (currently skipped), temperatures/fans (SMC)
- "Not Responding" detection for apps (needs Accessibility permission)
