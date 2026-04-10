#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
destination=${ROADFLARE_PREPUSH_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=26.4}

run() {
    printf '\n==> %s\n' "$1"
    shift
    "$@"
}

cd "$repo_root"

run "Running full RidestrSDK package tests" \
    swift test --package-path "$repo_root/RidestrSDK"

run "Running full RidestrUI package tests" \
    swift test --package-path "$repo_root/RidestrUI"

run "Building RoadFlare app target (catches app-level concurrency errors)" \
    xcodebuild \
    -project "$repo_root/RoadFlare/RoadFlare.xcodeproj" \
    -scheme RoadFlare \
    -destination "$destination" \
    build

run "Running RoadFlare logic unit tests (non-hosted)" \
    xcodebuild \
    -project "$repo_root/RoadFlare/RoadFlare.xcodeproj" \
    -scheme RoadFlareTests \
    -destination "$destination" \
    -parallel-testing-enabled NO \
    test
