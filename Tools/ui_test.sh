#!/bin/zsh
# UI test for the editor's drawing. Runs a copy of build/Braindump.app (own bundle ID, own
# notes file, test mode) through RenderTest.swift: lines are added and removed in different
# places, and after every step the real window is captured twice – as it is, and after a full
# redraw. Any difference means something on screen wasn't redrawn (e.g. a line shown twice).
# The app also checks its layout against a fresh one and logs copy, history and put-back results.
#
#   ./build.sh && Tools/ui_test.sh         → ok/FAIL per step, then the log
#   Tools/ui_test.sh --light               → the same in light mode
#
# Captures: $TMPDIR/braindump-ui-test/out.<step>a.png / b.png – outside ~/Documents, where a
# new test copy would first have to ask for access. The window opens in the background
# (open -g) and is never activated, so typing elsewhere is safe. Needs screen recording
# permission for the terminal (screencapture -l).
set -uo pipefail
cd "${0:A:h}/.."
[[ -d build/Braindump.app ]] || { echo "Run ./build.sh first"; exit 1; }

OUT_DIR=${TMPDIR:-/tmp}/braindump-ui-test
APP=$OUT_DIR/BraindumpTest.app
OUT=$OUT_DIR/out
EXTRA=()
[[ "${1:-}" == "--light" ]] && EXTRA=(-NSRequiresAquaSystemAppearance YES)

pkill -f "BraindumpTest.app/Contents/MacOS/Braindump" 2>/dev/null
rm -rf $OUT_DIR "$HOME/Library/Application Support/Braindump-Test/History"
mkdir -p $OUT_DIR/notes
cp Tools/ui_test_notes.txt $OUT_DIR/notes/Notes.txt
swiftc -O Tools/imgdiff.swift -o $OUT_DIR/imgdiff || exit 1

cp -R build/Braindump.app $APP
# A fresh bundle ID each run: a killed test copy may come back without a window next time.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.kai.BraindumpTest.r$(date +%s)" $APP/Contents/Info.plist
codesign --force --sign - $APP >/dev/null 2>&1
open -g -n $APP --args -notesPath $OUT_DIR/notes/Braindump.json -wnRenderTest $OUT "${EXTRA[@]}"

step=1
fails=0
while true; do
  for phase in a b; do
    waited=0
    while [[ ! -f $OUT.$step$phase.ready && ! -f $OUT.log && $waited -lt 300 ]]; do sleep 0.1; waited=$((waited + 1)); done
    [[ -f $OUT.$step$phase.ready ]] || break 2
    read window name < $OUT.$step$phase.ready
    screencapture -l $window -o -x $OUT.$step$phase.png
    touch $OUT.$step$phase.done
  done
  result=$($OUT_DIR/imgdiff $OUT.${step}a.png $OUT.${step}b.png)
  if [[ $result == 0 ]]; then
    echo "ok   $step: $name"
  else
    echo "FAIL $step: $name – not redrawn: $result"
    fails=$((fails + 1))
  fi
  step=$((step + 1))
done
for _ in {1..50}; do [[ -f $OUT.log ]] && break; sleep 0.1; done
pkill -f "BraindumpTest.app/Contents/MacOS/Braindump" 2>/dev/null

echo
cat $OUT.log 2>/dev/null || { echo "No log – the test app didn't finish"; exit 1; }
[[ $(grep -c "LAYOUT\|MISSING\|DIFFER" $OUT.log) -gt 0 ]] && fails=$((fails + 1))
echo
echo "$((step - 1)) steps, $fails failing"
[[ $fails -eq 0 ]]
