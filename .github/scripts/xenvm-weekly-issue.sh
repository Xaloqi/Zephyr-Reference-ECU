#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# Tracking issue for a failing weekly xenvm run: ONE per variant, stable title.
#   xenvm-weekly-issue.sh <doip|can> <pass|fail> <run-url> <dir with tail.txt>
# fail: open the issue, or comment on the open one. pass: comment on the open one and close it.
# DRY_RUN=1: look up the issue (read-only) and print what would be done. TITLE_PREFIX is for tests.
set -euo pipefail
V=$1; RESULT=$2; URL=$3; DIR=$4
TITLE="${TITLE_PREFIX:-}xenvm weekly run failing: $V"
DRY=${DRY_RUN:-0}
CMD=$([ "$V" = can ] && echo "xenvm/run.sh can" || echo "xenvm/run.sh")

# Lowest-numbered OPEN issue with exactly this title (never open a second one).
NUM=$(gh issue list --state open --limit 200 --json number,title \
      --jq "[.[] | select(.title == \"$TITLE\")] | sort_by(.number) | .[0].number // empty")

act() { if [ "$DRY" = 1 ]; then echo "DRY RUN would run: gh $*"; else gh "$@"; fi; }

if [ "$RESULT" = fail ]; then
  BODY=$(printf 'The weekly run of `%s` failed.\n\nRun: %s\n\n<details><summary>Last lines of the log</summary>\n\n```\n%s\n```\n</details>\n\nThe full serial log and stdout are attached to the run for 14 days. Independently of the cause, this is a real result: the demo no longer builds or no longer PASSes from its pinned sources on a fresh runner.' \
        "$CMD" "$URL" "$(cat "$DIR/tail.txt" 2>/dev/null || echo '(no log captured)')")
  if [ -n "$NUM" ]; then
    echo "open tracking issue #$NUM exists: commenting"
    act issue comment "$NUM" --body "$BODY"
  else
    echo "no open tracking issue titled '$TITLE': opening one"
    act issue create --title "$TITLE" --body "$BODY"
  fi
else
  if [ -n "$NUM" ]; then
    echo "run passes and issue #$NUM is open: commenting and closing"
    act issue comment "$NUM" --body "The weekly run of \`$CMD\` passes again: $URL"
    act issue close "$NUM"
  else
    echo "run passes, no open tracking issue: nothing to do"
  fi
fi
[ "$DRY" = 1 ] && { echo "--- body that would be posted on failure:"; echo "${BODY:-(only built on failure)}"; } || true
