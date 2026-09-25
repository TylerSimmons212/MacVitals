#!/bin/zsh
# Measure Mac Vitals' CPU while one dashboard page is visible.
#
#   scripts/rebuild.sh          # Release build (refuses to continue on failure)
#   scripts/perf.sh cpu 20      # → "cpu  5.0%   window: front→front"
#   EXTRA_ARGS="-foo YES" scripts/perf.sh cpu
#
# Occluded windows go idle by design, so the result is only meaningful when the window
# stays frontmost; the script reports that. Run from the repo root.
set -e
SECTION=$1; SECS=${2:-30}
APP=build/DerivedData/Build/Products/Release/MacVitals.app
HELPER=build/frontmost-window
[ -x $HELPER ] || swiftc -O scripts/frontmost-window.swift -o $HELPER 2>/dev/null
pkill -x MacVitals || true; while pgrep -x MacVitals >/dev/null; do sleep 0.3; done
open $APP --args -initialSection $SECTION ${=EXTRA_ARGS}   # ${=…}: zsh word-splitting for multiple args
sleep 8
pid=$(pgrep -x MacVitals)
front() { [ "$($HELPER)" = "Mac Vitals" ] && echo front || echo COVERED; }
cpu_seconds() { ps -o time= -p $pid | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
f1=$(front); a=$(cpu_seconds); sleep $SECS; b=$(cpu_seconds); f2=$(front)
printf "%-12s %5.1f%%   window: %s→%s\n" "$SECTION" $(echo "($b - $a) * 100 / $SECS" | bc -l) $f1 $f2
