#!/bin/zsh
# Build Release; exit non-zero (and print errors) if it fails, so we never measure a stale binary.
out=$(xcodebuild build -project MacVitals.xcodeproj -scheme MacVitals -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData 2>&1)
if echo "$out" | grep -q "BUILD SUCCEEDED"; then echo "build ok"; else echo "$out" | grep -E "error:" | sort -u | head; echo "BUILD FAILED"; exit 1; fi
