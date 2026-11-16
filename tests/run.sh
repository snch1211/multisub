#!/bin/bash
# Runs the extension's tests with Node (no packages to install).
# popup.test.js also needs Google Chrome for its headless page runs.
set -u
cd "$(dirname "$0")/extension" || exit 1
status=0
for t in shared background content layout popup; do
  printf '%-11s ' "$t"
  if out=$(node "$t.test.js" 2>&1); then
    echo "$out" | tail -1
  else
    status=1
    echo "FAILED"
    echo "$out" | grep -A6 -E '^FAIL|Error' | head -40
  fi
done
exit $status
