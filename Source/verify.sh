#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
task_test_binary="$(mktemp -t cuedeck-checks)"
trap 'rm -f "$task_test_binary"' EXIT
xcrun swiftc -O -parse-as-library Models.swift OSC.swift SheetImport.swift RemoteSheet.swift ProjectLibrary.swift Preview.swift Engine.swift Tests/Verification.swift -o "$task_test_binary" -framework Combine
"$task_test_binary" Resources/Show.json
