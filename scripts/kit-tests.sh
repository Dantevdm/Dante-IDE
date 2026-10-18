#!/bin/sh
# Runs the DanteKit tests with only the Command Line Tools installed (no Xcode), where
# `swift test` stops at SwiftTerm's Metal shader and can't load Swift Testing.
set -e
cd "$(dirname "$0")/.."
tools=/Library/Developer/CommandLineTools
swift build --target DanteKitTests -Xswiftc -plugin-path -Xswiftc $tools/usr/lib/swift/host/plugins/testing >/dev/null
bundle=.build/out/Products/Debug/DanteKitTests.xctest/Contents/MacOS/DanteKitTests
DYLD_FRAMEWORK_PATH=$tools/Library/Developer/Frameworks DYLD_LIBRARY_PATH=$tools/Library/Developer/usr/lib \
    $tools/usr/libexec/swift/pm/swiftpm-testing-helper --test-bundle-path "$bundle" "$bundle" --testing-library swift-testing "$@"
