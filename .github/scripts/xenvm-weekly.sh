#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
#
# Used by .github/workflows/xenvm-weekly.yml.
#
#   xenvm-weekly.sh run    <doip|can>   free disk, run the FULL xenvm/run.sh [can], record disk use
#   xenvm-weekly.sh finish <doip|can>   gate: exit 0 only if run.sh exited 0 AND its last line is PASS
#
# Everything the workflow uploads or reports lands in $XENVM_CI_OUT.
set -uo pipefail
MODE=${1:?usage: $0 run|finish doip|can}
V=${2:?usage: $0 run|finish doip|can}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${XENVM_CI_OUT:?XENVM_CI_OUT not set}
BUILD=${XENVM_BUILD_DIR:?XENVM_BUILD_DIR not set}
case $V in
  doip) ARGS=();    SERIAL=serial.log ;;
  can)  ARGS=(can); SERIAL=serial-can.log ;;
  *) echo "unknown variant $V"; exit 2 ;;
esac
mkdir -p "$OUT"

if [ "$MODE" = run ]; then
  echo "== disk at job start"; df -h / /mnt 2>/dev/null | tee "$OUT/df-before.txt"
  # The build dir and Docker's images share one filesystem on current runners (/ and
  # /mnt are the same 145 GB device); the run needs ~15 GB. If it is short, drop the
  # preinstalled toolchains this job never uses, and stop early if that is not enough.
  FREE_GB=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
  if [ "$FREE_GB" -lt 30 ]; then
    echo "== / has ${FREE_GB} GB free; removing unused preinstalled toolchains"
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL /usr/local/.ghcup
    df -h / | tee -a "$OUT/df-before.txt"
    FREE_GB=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
    [ "$FREE_GB" -ge 20 ] || { echo "FAIL: only ${FREE_GB} GB free on /, the run needs about 15"; exit 1; }
  fi
  sudo mkdir -p "$BUILD" && sudo chown "$(id -u):$(id -g)" "$BUILD"

  # Disk in use on / (build dir and Docker images), sampled every 10 s.
  ( while :; do df --output=used -B1 / | tail -1 | tr -dc 0-9; echo; sleep 10; done ) > "$OUT/disk-samples.txt" &
  SAMPLER=$!

  rm -f "$OUT/rc"
  "$REPO/xenvm/run.sh" "${ARGS[@]}" 2>&1 | tee "$OUT/stdout.log"
  RC=${PIPESTATUS[0]}
  echo "$RC" > "$OUT/rc"
  kill "$SAMPLER" 2>/dev/null || true
  echo "== disk at job end"; df -h / /mnt 2>/dev/null | tee "$OUT/df-after.txt"
  echo "== run.sh exit status $RC"
  exit "$RC"
fi

# --- finish: the gate -------------------------------------------------------------
# Pass needs a positive signal twice over (exit status 0 and a final line that starts
# with PASS). A missing rc file means run.sh was killed (timeout, runner loss): FAIL.
RC=$(cat "$OUT/rc" 2>/dev/null || echo missing)
LAST=$(grep -v '^[[:space:]]*$' "$OUT/stdout.log" 2>/dev/null | tail -n1)
if [ "$RC" = 0 ] && [[ "$LAST" == PASS* ]]; then RESULT=pass; else RESULT=fail; fi

# Artifacts: the serial log, run.sh's stdout, the build logs, disk use, the gate's verdict.
cp "$BUILD/$SERIAL" "$OUT/serial.log" 2>/dev/null || echo "(no $SERIAL: boot never ran)" > "$OUT/serial.log"
cp "$BUILD"/log-*.txt "$OUT/" 2>/dev/null || true
PEAK=$(awk 'NF { if (!n++) first=$1; if ($1>max) max=$1 } END { if (n) printf "%.1f", (max-first)/2^30; else print "?" }' "$OUT/disk-samples.txt" 2>/dev/null)
{
  echo "variant=$V result=$RESULT run_sh_exit=$RC"
  echo "final line: $LAST"
  echo "peak disk use above job start: ${PEAK} GiB (build dir + Docker images); free before/after: see df-before.txt, df-after.txt"
} | tee "$OUT/gate.txt"
echo "$RESULT" > "$OUT/result"
{ tail -n 40 "$OUT/stdout.log" 2>/dev/null
  # A failed build says only "see the logs": add the end of the newest build log.
  NEWEST=$(ls -t "$OUT"/log-*.txt 2>/dev/null | head -1)
  if [ "$RESULT" = fail ] && [ -n "$NEWEST" ]; then echo "--- tail of $(basename "$NEWEST")"; tail -n 30 "$NEWEST"; fi
} > "$OUT/tail.txt"

if [ "$RESULT" != pass ]; then
  echo "::error::xenvm $V: GATE FAILED (run.sh exit $RC, final line: ${LAST:-<none>})"
  exit 1
fi
echo "GATE PASSED: $LAST"
