#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -gt 0 ]]; then
    task_app_path="$1"
else
    task_app_path="../build/CueDeck.bundle"
fi
mkdir -p "$task_app_path/Contents/MacOS" "$task_app_path/Contents/Resources"
xcrun swiftc -O -parse-as-library -target arm64-apple-macosx14.0 -module-name CueDeck Models.swift OSC.swift SheetImport.swift RemoteSheet.swift ProjectLibrary.swift Preview.swift Engine.swift Editors.swift OperationViews.swift ProjectViews.swift SheetUpdateView.swift App.swift -o "$task_app_path/Contents/MacOS/CueDeck" -framework SwiftUI -framework AppKit -framework Combine
cp Resources/Show.json Resources/SourceSheet.json Resources/Guide.html "$task_app_path/Contents/Resources/"
cp Resources/Info.plist "$task_app_path/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$task_app_path/Contents/Resources/"
fi
codesign --force --sign - "$task_app_path"
print "Built CueDeck.app"
