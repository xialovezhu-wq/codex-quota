#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

# Compile the actual controller/provider without AppDelegate or any GUI startup.
# This needs only the installed Swift toolchain, not XCTest/Swift Testing.
swiftc -swift-version 6 -emit-module -emit-library -module-name CodexQuotaCore \
  "$project_dir"/Sources/CodexQuotaCore/*.swift \
  -emit-module-path "$temporary_dir/CodexQuotaCore.swiftmodule" \
  -o "$temporary_dir/libCodexQuotaCore.dylib"
swiftc -swift-version 6 -D DEBUG -parse-as-library \
  -I "$temporary_dir" -L "$temporary_dir" -lCodexQuotaCore \
  -Xlinker -rpath -Xlinker "$temporary_dir" \
  "$project_dir/Sources/CodexQuotaApp/EyeRestController.swift" \
  "$project_dir/Sources/CodexQuotaApp/CodexAppServerProvider.swift" \
  "$project_dir/Tests/CodexQuotaAppTests/LifecycleTests.swift" \
  -o "$temporary_dir/lifecycle-tests"
"$temporary_dir/lifecycle-tests" "$@"
