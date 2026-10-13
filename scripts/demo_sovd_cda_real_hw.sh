#!/usr/bin/env bash
# =============================================================================
# Xaloqi Zephyr-Reference-ECU
# scripts/demo_sovd_cda_real_hw.sh
#
# PURPOSE: Prove that this ECU -- real firmware, on real NUCLEO-H753ZI
#          hardware, over a real physical CAN bus -- answers real diagnostic
#          requests routed over SOVD, from the real Eclipse OpenSOVD Classic
#          Diagnostic Adapter (CDA). No simulator on either side. This is
#          Phase 3 (see README.md): BUILD-1's capability
#          (Xaloqi/EDS's scripts/demo_can_sovd_cda_interop.sh), absorbed
#          here and retargeted at this repo's own real hardware instead of
#          EDS's native_sim + vxcan.
#
#          This script needs the real board, already flashed and on the
#          bus -- unlike EDS's own version, which needs only Docker, this
#          one cannot run on a machine with no NUCLEO-H753ZI attached. That
#          is Phase 3's whole point ("real CAN", not a simulated one) --
#          stated plainly, not a limitation apologized for.
#
#          What it exercises, in order, against this repo's own real
#          firmware, none of it modified for this demo:
#            1. Discovery: the CDA's own CAN probe finds this ECU answering
#               TesterPresent on physical addressing (0x7E0 -> 0x7E8).
#            2. A multi-frame-capable ISO-TP read (ReadDataByIdentifier,
#               DID 0xF190).
#            3. Session control (UDS SID 0x10) -- required before step 4.
#            4. SecurityAccess (SID 0x27) with real cryptography -- this
#               ECU's AES-128-CMAC seed/key exchange (the same algorithm
#               Xaloqi EDS's core/uds_security_algo.c implements),
#               computed independently by this script from the real seed
#               bytes received over the wire.
#            5. RoutineControl (SID 0x31) Start -- a real routine,
#               dispatched by this firmware's real service_0x31.c handler.
#
#          HONESTY, SAID PLAINLY, NOT BURIED:
#            - This is a CAN-only demo. DoIP does NOT work against the real
#              CDA: it discovers DoIP gateways exclusively by UDP Vehicle
#              Identification, and EDS has never implemented that side
#              (EDS#392). Nothing below exercises DoIP.
#            - This ECU's two CDA-interop-only entries (DID 0xF100,
#              routine 0x1001 "SelfTest") exist to match the CDA's own
#              shipped FLXC1000.mdd fixture, not because this ECU needed
#              them otherwise -- see README.md "Phase 3" and
#              diagnostics_config.yaml's own comments. A custom ODX fixture
#              describing this ECU's own real identity would be the
#              cleaner alternative; it isn't available for the same reason
#              EDS's own demo documents (the CDA's PDX-to-MDD converter
#              isn't publicly distributable).
#            - The VIN this demo reads back is all zero bytes --
#              did_read_vehicleidentificationnumber()'s generated stub,
#              never wired to anything real. Correct for an unconfigured
#              DID, not a defect.
#            - This proves SOVD-over-CAN interop. It does not prove this
#              ECU's own door-ajar/window-stall application logic through
#              SOVD -- those aren't in the CDA's fixture at all, so SOVD
#              has no route to them; see README.md for how those were
#              verified instead (raw ISO-TP, this repo's own tooling).
#
#          LICENSING: this script never invokes tools/codegen.py or
#          tools/testgen.py. The firmware it talks to was built and
#          flashed exactly as README.md documents, with the pre-committed
#          generated/ tree -- no commercial EDS licence needed to run this.
#
# PREREQUISITES:
#   - This repo's firmware already flashed to a NUCLEO-H753ZI, wired per
#     README.md's bill of materials, with its physical/functional CAN
#     filters both up (this repo's src/main.c sets both).
#   - A host SocketCAN interface named "slcan0" (or override via
#     XALOQI_DEMO_CAN_IF) already up and bridged to that hardware -- see
#     README.md "Phase 2" for the MKS CANable / slcand setup. This script
#     does not create it.
#   - Docker, to build the real CDA from source (cached after first run --
#     the CDA itself needs no hardware and nothing EDS-specific, so this
#     part of the setup is identical to EDS's own demo).
#
# USAGE:
#   bash scripts/demo_sovd_cda_real_hw.sh
#
# ENV OVERRIDES:
#   XALOQI_DEMO_CACHE_DIR   base cache directory (default: ~/.cache/xaloqi-zref-demo)
#   XALOQI_DEMO_CAN_IF      host SocketCAN interface name (default: slcan0)
#   CDA_REF                 git ref of the CDA to build (default: the exact
#                           commit this demo was last verified against)
#
# EXIT CODES:
#   0  Demo completed: real firmware answered every step above through the
#      real CDA, over the real physical CAN bus.
#   1  A prerequisite is missing, or a build/run/verification step failed --
#      message says which, and where to find the failing step's log.
# =============================================================================

set -euo pipefail

CAN_IF="${XALOQI_DEMO_CAN_IF:-slcan0}"
CDA_REF="${CDA_REF:-b470ab059a216803a58bbae8a14baef039466f45}"
CACHE_DIR="${XALOQI_DEMO_CACHE_DIR:-$HOME/.cache/xaloqi-zref-demo}"
CDA_CACHE_DIR="$CACHE_DIR/classic-diagnostic-adapter"
RUN_DIR="$CACHE_DIR/run"

echo "============================================================"
echo "  Zephyr-Reference-ECU <-> real Eclipse OpenSOVD CDA,"
echo "  over real CAN, on real hardware"
echo "============================================================"
echo

# --- Prerequisite: the host CAN interface must already be up ---------------
if ! ip link show "$CAN_IF" >/dev/null 2>&1; then
  echo "ERROR: CAN interface '$CAN_IF' does not exist." >&2
  echo "  This script does not create it -- see README.md 'Phase 2' for" >&2
  echo "  the MKS CANable / slcand setup (or pass XALOQI_DEMO_CAN_IF=<name>" >&2
  echo "  if your interface is named differently)." >&2
  exit 1
fi
if ! ip link show "$CAN_IF" | grep -q "UP"; then
  echo "ERROR: CAN interface '$CAN_IF' exists but is not UP." >&2
  echo "  sudo ip link set up $CAN_IF" >&2
  exit 1
fi
echo "CAN interface  : $CAN_IF (up)"
echo "Cache dir      : $CACHE_DIR"
echo

mkdir -p "$CACHE_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found on PATH -- needed to build the real CDA" >&2
  echo "  from source (one-time, cached after)." >&2
  exit 1
fi

# --- Step 1: clone + build the real CDA, cached across runs ----------------
echo "--- [1/3] Building the real Eclipse CDA (cached after first run) ---"
if [ ! -d "$CDA_CACHE_DIR/.git" ]; then
  git clone https://github.com/eclipse-opensovd/classic-diagnostic-adapter.git "$CDA_CACHE_DIR" \
    > "$CDA_CACHE_DIR.clone.log" 2>&1 \
    || { echo "ERROR: git clone failed -- see $CDA_CACHE_DIR.clone.log" >&2; exit 1; }
fi
git -C "$CDA_CACHE_DIR" fetch origin --quiet
git -C "$CDA_CACHE_DIR" checkout --quiet "$CDA_REF"

CDA_BINARY="$CDA_CACHE_DIR/target/release/opensovd-cda"
if [ ! -x "$CDA_BINARY" ]; then
  docker run --rm \
    -v "$CDA_CACHE_DIR":/work \
    rust:latest bash -c "
      git config --global --add safe.directory /work
      cd /work && cargo build --release --features can -p opensovd-cda
    " > "$CDA_CACHE_DIR.build.log" 2>&1 \
    || { echo "ERROR: CDA build failed -- see $CDA_CACHE_DIR.build.log" >&2; tail -40 "$CDA_CACHE_DIR.build.log" >&2; exit 1; }
fi
if [ ! -x "$CDA_BINARY" ]; then
  echo "ERROR: CDA build reported success but $CDA_BINARY is missing." >&2
  exit 1
fi
echo "  built: $CDA_BINARY"
echo

# --- Step 2: configure and start the CDA against the real bus --------------
echo "--- [2/3] Starting the real CDA against $CAN_IF ---"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR/mdds" "$RUN_DIR/flash"
cp "$CDA_CACHE_DIR/testcontainer/odx/FLXC1000.mdd" "$RUN_DIR/mdds/"

# Same config EDS's own demo uses, with the interface pointed at the real
# bus instead of vxcan, and the [ecu.FLXC1000] protocol override dropped --
# it mismatches this fixture's real embedded protocol
# (eclipse-opensovd/classic-diagnostic-adapter#619, filed upstream; see
# EDS's own demo script for the identical fix).
sed \
  -e "s/interface = \"vxcan0\"/interface = \"$CAN_IF\"/" \
  "$CDA_CACHE_DIR/opensovd-cda-can.toml" > "$RUN_DIR/cda.toml"
python3 -c "
import re
p = '$RUN_DIR/cda.toml'
s = open(p).read()
s = re.sub(r'\[ecu\.FLXC1000\]\nprotocol = \"UDS_CAN\"\n\n?', '', s)
open(p, 'w').write(s)
"

(cd "$RUN_DIR" && CDA_CONFIG_FILE="$RUN_DIR/cda.toml" RUST_LOG=info \
  "$CDA_BINARY" > "$RUN_DIR/cda.log" 2>&1 &)
CDA_PID=""
for _ in $(seq 1 20); do
  CDA_PID="$(pgrep -f "$CDA_BINARY.*$RUN_DIR/cda.toml" || true)"
  [ -n "$CDA_PID" ] && break
  sleep 0.2
done
cleanup() { [ -n "$CDA_PID" ] && kill "$CDA_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "  waiting for the CDA to discover this ECU on the CAN bus..."
ONLINE=0
for _ in $(seq 1 20); do
  sleep 1
  if curl -s http://127.0.0.1:20002/Vehicle/v15/components/flxc1000 \
       2>/dev/null | grep -q '"state":"Online"'; then
    ONLINE=1
    break
  fi
done
if [ "$ONLINE" -ne 1 ]; then
  echo "ERROR: this ECU never reached 'Online' from the CDA's point of view. Log:" >&2
  cat "$RUN_DIR/cda.log" >&2 || true
  exit 1
fi
VARIANT="$(curl -s http://127.0.0.1:20002/Vehicle/v15/components/flxc1000 \
  | sed -n 's/.*"variant":{"name":"\([^"]*\)".*/\1/p')"
echo "  this ECU discovered and held Online by the real CDA (variant: $VARIANT)."
echo

auth_token() {
  curl -s -X POST http://127.0.0.1:20002/vehicle/v15/authorize \
    -H 'Content-Type: application/json' \
    -d '{"client_id":"demo","client_secret":"demo"}' \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

# --- Step 3: session control, SecurityAccess, RoutineControl, a read ------
echo "--- [3/3] Session control, SecurityAccess (real crypto), RoutineControl, VIN read ---"

TOKEN="$(auth_token)"
if [ -z "$TOKEN" ]; then
  echo "ERROR: did not get an access token from the CDA's dev-mode /authorize endpoint." >&2
  exit 1
fi

echo "  [a] ISO-TP read: ReadDataByIdentifier(VINDataIdentifier, 0xF190)"
RESULT="$(curl -s -w '\nHTTP_STATUS:%{http_code}' -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:20002/Vehicle/v15/components/flxc1000/data/VINDataIdentifier)"
echo "$RESULT" | sed 's/^/      /'
echo "$RESULT" | grep -q "HTTP_STATUS:200" \
  || { echo "ERROR: VIN read did not return 200." >&2; exit 1; }

echo "  [b] acquiring component lock (required before session/security changes)"
LOCK_RESULT="$(curl -s -w '\nHTTP_STATUS:%{http_code}' \
  -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://127.0.0.1:20002/Vehicle/v15/components/flxc1000/locks -d '{"lock_expiration": 100000}')"
echo "$LOCK_RESULT" | sed 's/^/      /'
echo "$LOCK_RESULT" | grep -q "HTTP_STATUS:201" \
  || { echo "ERROR: component lock was not granted." >&2; exit 1; }

echo "  [c] session control: switching to Extended session (UDS SID 0x10)"
SESSION_RESULT="$(curl -s -w '\nHTTP_STATUS:%{http_code}' \
  -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://127.0.0.1:20002/Vehicle/v15/components/flxc1000/modes/session -d '{"value":"extended"}')"
echo "$SESSION_RESULT" | sed 's/^/      /'
echo "$SESSION_RESULT" | grep -q "HTTP_STATUS:200" \
  || { echo "ERROR: session switch to Extended failed." >&2; exit 1; }

echo "  [d] SecurityAccess (SID 0x27): RequestSeed, sub-function 0x03"
SEED_RESULT="$(curl -s -X PUT \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://127.0.0.1:20002/Vehicle/v15/components/flxc1000/modes/security -d '{"value":"3_RequestSeed"}')"
echo "      $SEED_RESULT"
SEED_HEX="$(echo "$SEED_RESULT" | sed -n 's/.*"Request_Seed":"\([^"]*\)".*/\1/p')"
if [ -z "$SEED_HEX" ]; then
  echo "ERROR: did not receive a seed from RequestSeed." >&2
  exit 1
fi

# Real, independent AES-128-CMAC -- not a lookup table, not pre-computed --
# against the real seed bytes this ECU just sent over the wire. This
# repo's level-2 key is EDS's own documented placeholder
# (core/uds_security_algo.c, s_level_keys[1]):
# 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f.
echo "  [e] computing AES-128-CMAC(seed, documented Level-2 key), truncated to 4 bytes"
KEY_HEX="$(python3 -c "
from cryptography.hazmat.primitives import cmac
from cryptography.hazmat.primitives.ciphers import algorithms

level2_key = bytes.fromhex('101112131415161718191a1b1c1d1e1f')
seed_tokens = '$SEED_HEX'.split()
seed = bytes(int(t, 16) for t in seed_tokens)
c = cmac.CMAC(algorithms.AES(level2_key))
c.update(seed)
key = c.finalize()[:4]
print(' '.join(f'0x{b:02x}' for b in key))
")"
echo "      seed: $SEED_HEX"
echo "      key : $KEY_HEX"

echo "  [f] SecurityAccess (SID 0x27): SendKey, sub-function 0x04"
SENDKEY_RESULT="$(curl -s -w '\nHTTP_STATUS:%{http_code}' \
  -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://127.0.0.1:20002/Vehicle/v15/components/flxc1000/modes/security \
  -d "{\"value\":\"Level_3\",\"Key\":{\"Send_Key\":\"$KEY_HEX\"}}")"
echo "$SENDKEY_RESULT" | sed 's/^/      /'
echo "$SENDKEY_RESULT" | grep -q "HTTP_STATUS:200" \
  || { echo "ERROR: SendKey was rejected -- the ECU did not accept the computed key." >&2; exit 1; }

SEC_STATUS="$(curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:20002/Vehicle/v15/components/flxc1000/modes/security)"
echo "      security status: $SEC_STATUS"
echo "$SEC_STATUS" | grep -q '"value":"Level_3"' \
  || { echo "ERROR: security status did not confirm Level_3 unlocked." >&2; exit 1; }

echo "  [g] RoutineControl (SID 0x31): starting routine 'SelfTest' (ID 0x1001)"
ROUTINE_RESULT="$(curl -s -w '\nHTTP_STATUS:%{http_code}' \
  -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://127.0.0.1:20002/Vehicle/v15/components/flxc1000/operations/SelfTest/executions -d '{}')"
echo "$ROUTINE_RESULT" | sed 's/^/      /'
echo "$ROUTINE_RESULT" | grep -q "HTTP_STATUS:200" \
  || { echo "ERROR: RoutineControl Start did not return 200." >&2; exit 1; }
echo "$ROUTINE_RESULT" | grep -q '"RoutineId":4097' \
  || { echo "ERROR: RoutineControl response did not echo RoutineId 4097 (0x1001)." >&2; exit 1; }

echo
echo "============================================================"
echo "  This ECU answered every step above through the real Eclipse"
echo "  OpenSOVD CDA, over real CAN, on real hardware. Nothing above"
echo "  was mocked:"
echo "    - ISO-TP read                            : PASS"
echo "    - session control (SID 0x10)             : PASS"
echo "    - SecurityAccess, real AES-128-CMAC (0x27): PASS"
echo "    - RoutineControl (SID 0x31)               : PASS"
echo "============================================================"
echo
echo "The VIN above reads as all zero bytes -- this ECU's example DID"
echo "handler returns a placeholder, which is correct for an unconfigured"
echo "value, not a defect."
echo
echo "What this does NOT prove: DoIP (the real CDA discovers DoIP gateways"
echo "only by UDP Vehicle Identification, which EDS has never implemented --"
echo "EDS#392); the pytest/CAPL test-generation half of EDS working without"
echo "a commercial licence (it does not -- see README.md); or this ECU's"
echo "own door-ajar/window-stall application logic through SOVD (the CDA's"
echo "fixture has no route to it -- see README.md for how that was"
echo "verified instead)."
