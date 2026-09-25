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
   - `.rollingNumber` only for values that change rarely (health score, counts); `DetailStat(rolls:)` is opt-in
   - list animations key on *status* (e.g. check severity), not on live text
2. **Never wrap sample updates in a global `withAnimation`** (51% → 15% when removed).
3. **No continuously animating views behind glass.** Motion is event-driven only.
4. **Don't publish when nobody is looking.** `SystemMonitor` records into private storage and only
   publishes while a window reports itself visible (`VisibilityTracker`).
5. **Pre-render app icons to small bitmaps**; full icons were resampled on the CPU every refresh.
6. rusage CPU times are **Mach ticks**, not nanoseconds (×125/3 on Apple silicon).

Charts, Liquid Glass and large lists measured as cheap; animation was the cost.

## Known gaps / next

- Notifications on critical changes (rate-limited)
- SSD wear level and total data written (Disk › Under the hood)
- Clean Up extras: duplicates, a small honest maintenance set, Mail attachments
- Privileged helper for root-owned processes (currently skipped), temperatures/fans (SMC)
- "Not Responding" detection for apps (needs Accessibility permission)
