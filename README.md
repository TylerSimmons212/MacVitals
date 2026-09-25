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

| State | CPU |
|---|---|
| Menu bar only (window closed) | ~0% |
| Dashboard visible, 2s refresh | ~15–20% of one core |

Things that looked harmless and weren't:

1. **Never wrap sample updates in a global `withAnimation`.** Animating the whole tree re-runs layout
   every frame (51% → 15%). Animate locally with value-scoped `.animation` / `.rollingNumber`.
2. **No continuously animating views behind glass.** A drifting backdrop made every glass surface
   re-sample each frame (+30% in WindowServer). Motion here is event-driven only.
3. **Don't publish when nobody is looking.** SwiftUI re-renders hidden MenuBarExtra panels and occluded
   windows when observed data changes. `SystemMonitor` records into private storage and only publishes
   while a window reports itself visible (`VisibilityTracker`); it also skips per-process sampling then.
4. **Pre-render app icons to small bitmaps.** Full multi-resolution icons were resampled on the CPU every refresh.
5. rusage CPU times are **Mach ticks**, not nanoseconds (×125/3 on Apple silicon).

Profile with: `build/measure.sh` (CPU-time delta over 20s) and `sample <pid> 10`.

## Known gaps / next

- Privileged helper for root-owned processes (they're currently skipped)
- Notifications on critical changes (rate-limited)
- Persisted 30-day history
- Per-app network usage, temperatures/fans (SMC)
