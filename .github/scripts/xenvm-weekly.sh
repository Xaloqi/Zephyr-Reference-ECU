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
  # Docker's images live on /, the build dir on /mnt. If / is short (needs ~12 GB of
  # images and layers), drop the preinstalled toolchains this job never uses.
  FREE_GB=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
  if [ "$FREE_GB" -lt 25 ]; then
    echo "== / has ${FREE_GB} GB free; removing unused preinstalled toolchains"
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL /usr/local/.ghcup
    df -h / | tee -a "$OUT/df-before.txt"
  fi
  sudo mkdir -p "$BUILD" && sudo chown "$(id -u):$(id -g)" "$BUILD"

  # Peak use of both filesystems, sampled every 10 s.
  ( while :; do echo "$(df --output=used -B1 / | tail -1 | tr -dc 0-9) $(df --output=used -B1 /mnt | tail -1 | tr -dc 0-9)"; sleep 10; done ) > "$OUT/disk-samples.txt" &
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
read -r PEAK_ROOT PEAK_MNT < <(awk 'NF==2 { if ($1>a) a=$1; if ($2>b) b=$2 } END { printf "%.1f %.1f\n", a/2^30, b/2^30 }' "$OUT/disk-samples.txt" 2>/dev/null || echo "0 0")
{
  echo "variant=$V result=$RESULT run_sh_exit=$RC"
  echo "final line: $LAST"
  echo "peak disk used: / ${PEAK_ROOT:-?} GiB (Docker images), /mnt ${PEAK_MNT:-?} GiB (build dir); free at start/end: see df-*.txt"
} | tee "$OUT/gate.txt"
echo "$RESULT" > "$OUT/result"
{ tail -n 40 "$OUT/stdout.log" 2>/dev/null
  NEWEST=$(ls -t "$OUT"/log-*.txt 2>/dev/null | head -1)
  [ -n "$NEWEST" ] && { echo "--- tail of $(basename "$NEWEST")"; tail -n 40 "$NEWEST"; }
} > "$OUT/tail.txt"

if [ "$RESULT" != pass ]; then
  echo "::error::xenvm $V: GATE FAILED (run.sh exit $RC, final line: ${LAST:-<none>})"
  exit 1
fi
echo "GATE PASSED: $LAST"
