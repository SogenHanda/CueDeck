#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
if pgrep -x CueDeck >/dev/null; then
    print "先にCueDeckをHOLDにして終了してください。"
    exit 1
fi
task_build_dir="$(mktemp -d -t cuedeck-install)"
trap 'rm -rf "$task_build_dir"' EXIT
./build.sh "$task_build_dir/CueDeck.app"
if [[ -d /Applications/CueDeck.app ]]; then
    ditto -c -k --keepParent /Applications/CueDeck.app ../app-backup.zip
fi
ditto "$task_build_dir/CueDeck.app" /Applications/CueDeck.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/CueDeck.app
print "Updated /Applications/CueDeck.app"
