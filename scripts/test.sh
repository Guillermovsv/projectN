#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/ModuleCache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/ModuleCache}"

# Command Line Tools ships Swift Testing outside SwiftPM's default search paths.
# Full Xcode installations can use SwiftPM's normal framework discovery.
developer_dir="$(xcode-select -p)"
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
testing_flags=()
if [ -d "$testing_frameworks/Testing.framework" ]; then
  testing_flags=(
    -Xswiftc -F -Xswiftc "$testing_frameworks"
    -Xlinker -F -Xlinker "$testing_frameworks"
    -Xlinker -rpath -Xlinker "$testing_frameworks"
    -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib"
  )
fi

# Never let tests see your real ~/.projectn: give the whole run a throw-away home.
export PROJECTN_HOME="${TMPDIR%/}/projectn-tests-$$-$RANDOM"

# The agent helper isn't a test dependency, so build it explicitly (tests run it as Claude Code would).
swift build --product pn-agent -j "${PROJECTN_BUILD_JOBS:-4}"

swift test --disable-sandbox --disable-xctest --enable-swift-testing \
  -j "${PROJECTN_BUILD_JOBS:-4}" "${testing_flags[@]}" "$@"
