The EDS MCP server (`tools/mcp_server.py`) ships in the EDS commercial toolchain and needs a Developer licence. It is not part of this repo or of the public EDS repo.

# An AI-assisted change, end to end

This page walks through one change to this ECU made from Claude Code with the EDS
MCP server: two new DIDs, from a YAML scaffold to a read on a real CAN bus. The change
itself is **not** in this repo; this page describes it so you can make your own.

Where the output comes from (EDS v1.26.1, the version `west.yml` pins):

- **Tool calls, campaign, build:** re-run on 2026-10-30 on EDS v1.26.1 with the v1.26.1
  Developer ZIP unzipped over the tag, `xaloqi-tester` 1.5.10 and a NUCLEO-H753ZI build.
  The tools were called directly over MCP stdio (they are deterministic and call no
  model), so the output is what the server returns.
- **Two caught failures** (the write-security rejection and the default-session write) are
  quoted exactly as captured on 2026-10-27 on EDS v1.25.0. Both checks still fire on
  v1.26.1 with the same messages.
- **Frames on real CAN:** captured on 2026-10-30 on EDS v1.26.1 firmware (step 6).

The MCP server gives the AI assistant four tools. None of them calls a model, and none
of them edits your files:

| Tool | Does |
|---|---|
| `generate_did_config` | Returns a `diagnostics_config.yaml` scaffold for the DIDs you describe |
| `validate_asil_b` | Runs `codegen.py --dry-run` at ASIL-B on a config file (or on YAML text) and returns violations |
| `run_codegen` | Runs `codegen.py` on a config file and writes `generated/` |
| `explain_uds_error` | Explains an NRC in terms of the EDS check that returns it |

The assistant chooses the calls and makes the edits with its own file tools. A
person reviews each step. What the tools add is that mistakes get caught before
they reach C, and the run below shows several.

## Setup

1. **EDS at the version `west.yml` pins** (v1.26.1 at the time of writing), with the
   Developer ZIP of the same version unzipped over it, as EDS's `INSTALL.md` describes.
   `mcp_server.py` calls the `tools/codegen.py` next to it, so it does not run from the
   ZIP alone.
2. **A Developer licence** (`~/.xaloqi/license.key` or `XALOQI_LICENSE_KEY`). Without
   one the server prints `LICENSE ERROR: No Xaloqi EDS license key found.` and exits 1.
3. **Point the example config at your install:**
   ```sh
   export XALOQI_EDS_ROOT=/path/to/your/EDS   # the tree you unzipped the ZIP over
   ```
   [`.mcp.json`](../.mcp.json) at this repo's root registers the server as
   `xaloqi-eds`, using that variable. Check with `claude mcp get xaloqi-eds`: it shows
   `✓ Connected` when the path and licence are good, and `✗ Failed to connect` when
   `XALOQI_EDS_ROOT` is unset. If you add the server during a session, start a new
   session to load it.

## The change

- `BCM_BatteryVoltage_mV` (0x0413, uint16): supply voltage, simulated in
  `src/bcm_state.c`. **Read-only** over UDS: the application owns the value
  (`source: app`).
- `BCM_InteriorLightTimeout_s` (0x0414, uint8): a calibration value, writable in the
  extended session.

### 1. Scaffold, then merge by hand

`generate_did_config` with both DIDs returns a complete scaffold: `schema_version`,
`metadata`, `timing`, the two `dids` entries, and empty `dtcs`/`routines`. A DID passed
with `source: app` comes back marked, with a header naming the function the application
must define:

```yaml
# Application-owned DIDs (source: app). codegen generates no body for
# these; define them in application code (prototypes in generated/
# did_handlers.h). A missing one is a link error:
#   did_read_bcm_batteryvoltage_mv()
...
  - id:   "0x0413"
    name: "BCM_BatteryVoltage_mV"
    access:
      - read
    min_session:          "extended"
    read_security_level:  0
    write_security_level: 0
    data_length:          2
    source:               app
```

The scaffold is still not a drop-in replacement for this repo's file: its `can:` block is
a commented reminder (the IDs have no default, because 0x7DF is the functional broadcast
ID), and the repo has its own. Copy only the two `dids` entries into
`diagnostics_config.yaml`, after `BCM_DoorCycleCount`.

### 2. Validate: the write-security rejection

For a writable DID the scaffold defaults `write_security_level` to 1. To see the check
working, the run deliberately set it to 0 on 0x0414. `validate_asil_b` rejected it:

```
[codegen] ERROR: SAFETY [HIGH-1]: dids[7] (id='0x0414') 'BCM_InteriorLightTimeout_s' has write access but write_security_level=0.  ASIL-B policy (ISO 26262-6) requires that every write-capable DID is protected by a SecurityAccess challenge. FIX: set write_security_level >= 1 in diagnostics_config.yaml for this DID. ...
```

EDS v1.26.1 returns the same check, for the same DID (`dids[7]`). With
`write_security_level: 1` it returns:

```json
{
  "valid": true,
  "violations": [],
  "warnings": ["[codegen] WARN: ASIL-B safety validation active."],
  "config_path": ".../diagnostics_config.yaml",
  "config_sha256": "309a7b99ac19eee86c0e37e6b985c65e3bb6845b6096667263f0c84f1fab5392"
}
```

Pass `config_path` rather than the YAML text: the assistant no longer re-types the file
(it used to lose characters in comment lines), and `config_sha256` lets you check that
the file validated is the file you meant. The banner is in `warnings`; `violations` holds
only real violations.

### 3. A read-only DID the app owns: `source: app`

`BCM_BatteryVoltage_mV` is a value the application computes and a tester must not
overwrite. Declare it `source: app` with `access: [read]`:

```yaml
  - id:   "0x0413"
    name: "BCM_BatteryVoltage_mV"
    source: app
    access:
      - read
    min_session:          "extended"
    read_security_level:  0
    write_security_level: 0
    data_length:          2
```

codegen then emits only the prototype `did_read_bcm_batteryvoltage_mv()` and the safety
wrapper for it: no backing store and **no `did_write_bcm_batteryvoltage_mv()`**. The
application defines the read function (step 5); forgetting it is a link error, and a
tester's write to the DID is refused. (On v1.25.0 the only way to set a DID's value from
the application was the generated `did_write_*()`, which exists only for writable DIDs,
so this DID had to be `[read, write]` with a security level
([EDS-toolchain#201](https://github.com/Xaloqi/EDS-toolchain/issues/201), fixed).)

The calibration DID is the opposite case: a value the tester writes. A writable DID in
`min_session: "default"` is rejected, because 0x2E is refused in the default session. This
check was caught on 2026-10-27, on v1.25.0, while 0x0413 was still writable (hence
`dids[6]`); the same message comes back on v1.26.1 for any writable DID left in `default`:

```
[codegen] ERROR: VALIDATION: dids[6]: DID has write access with min_session 'default', but WriteDataByIdentifier (0x2E) is only accepted in a non-default session (core/uds_access_table.c), so this DID can never be written. FIX: set min_session to 'extended' (or 'programming').
```

Both DIDs end up in `extended`; the calibration DID is writable with a security level:

```yaml
  - id:   "0x0414"
    name: "BCM_InteriorLightTimeout_s"
    access:
      - read
      - write
    min_session:          "extended"
    read_security_level:  0
    write_security_level: 1
    data_length:          1
```

### 4. Generate, and put the hooks back

`run_codegen` writes all 11 files in `generated/`. Absolute paths work for `config_path`
and `output_dir`, as do paths relative to `XALOQI_EDS_ROOT`:

```json
{
  "success": true,
  "output_files": [".../generated/did_handlers.c", ".../generated/did_handlers.h",
                   ".../generated/did_safety_wrappers.c", ".../generated/did_safety_wrappers.h",
                   ".../generated/dtc_config.h", ".../generated/generated_config.h",
                   ".../generated/routine_handlers.c", ".../generated/routine_handlers.h",
                   ".../generated/safety_config.h", ".../generated/uds_init.c",
                   ".../generated/uds_init.h"],
  "returncode": 0
}
```

(On v1.25.0 an absolute path outside the EDS tree wrote the files and then returned an
error, [EDS-toolchain#200](https://github.com/Xaloqi/EDS-toolchain/issues/200), fixed.)
The result's `stdout` also carries codegen's licence banner line, which names the
licensee: leave it out when you paste a transcript
([EDS-toolchain#227](https://github.com/Xaloqi/EDS-toolchain/issues/227)).

Regenerating replaces `generated/routine_handlers.c`'s four `[APP HOOK]` bodies with
TODO stubs. The configure-time check catches it:

```
CMake Error at CMakeLists.txt:201 (message):
  [REF-ECU] ERROR: generated/routine_handlers.c no longer contains the [APP
  HOOK] markers.
```

Reapply the four bodies documented in `src/bcm_state.h`
(see [README](../README.md) "The one hand-edited `generated/` file"). This change
touched no routines: on v1.26.1 the regenerated file is identical, apart from its
timestamp, to a regeneration of the unchanged YAML. So restoring the committed file
(`git checkout -- generated/routine_handlers.c`) is the same as reapplying the bodies.
If you change routines, reapply the bodies by hand onto the new file.

One more thing to expect: the files committed here were generated by an earlier EDS, so
regenerating on v1.26.1 also brings in template changes unrelated to your DIDs (for
example `uds_init.c`). To keep your diff reviewable, regenerate the unchanged YAML first
and commit that on its own.

### 5. The app side

In `src/bcm_state.c`, beside `bcm_push_door_cycle_count()`:

- **define `did_read_bcm_batteryvoltage_mv()`**: it returns a simulated supply, a
  12500–12700 mV triangle wave stepped on every monitor tick (two bytes, big-endian);
- seed the timeout once at init with `did_write_bcm_interiorlighttimeout_s()` (30 s).

The NUCLEO build (`nucleo_h753zi`, EDS v1.26.1) then succeeds, FLASH 111,948 B (5.34 %),
RAM 59,460 B (11.34 %), with no warnings from `src/` or `generated/` (only the vendor HAL's
`-Wundef`, as before).

### 6. Prove it

**Free virtual campaign.** Add the calibration DID to `campaigns/reference_bcm.yaml`:
a write **before** SecurityAccess that must be refused with NRC 0x33, then after the key a
write, a read back and an assert. The run on `xaloqi-tester` 1.5.10 passed **23/23**:

```
  [03/23] write_did(0x0414)                  → OK           (0 ms)    # expect_nrc: 0x33
  [04/23] security_access(level=1)           → OK           (22 ms)
  ...
  [12/23] write_did(0x0414)                  → OK           (0 ms)
  [13/23] read_did(0x0414)                   → OK           (0 ms)
  [14/23] assert                             → OK           (0 ms)
```

The refused write belongs in this job. Until `xaloqi-tester` 1.5.9 the free virtual ECU
accepted that write, and the step failed with `Expected NRC 0x33 but step produced a
positive response` ([TestLab#93](https://github.com/Xaloqi/TestLab/issues/93), fixed in
TestLab#97). The same campaign on 1.5.8 still fails exactly there; on 1.5.9 and 1.5.10 it
passes.

`BCM_BatteryVoltage_mV` is not in the virtual campaign. The free virtual ECU is a small
built-in simulator, not an interpreter of `diagnostics_config.yaml`: it knows a DID outside
its own four only after a write, and a write is exactly what this read-only DID refuses on
the real ECU. Its behaviour is shown by codegen (no `did_write_*()` exists) and by the
frames below.

**Real CAN.** Captured on 2026-10-30 on a NUCLEO-H753ZI running this change on **EDS
v1.26.1**: the demo build (both DIDs, `0x0413` as `source: app`) on top of a regeneration of
the unchanged YAML. After flashing, the boot log reports `UDS stack ready: 9 DIDs  2 DTCs`.
From the host (CANable2, ECU on physical 0x7E0/0x7E8), frames as observed:

```
7E0#03220413CCCCCCCC   7E8#037F2231            read 0x0413, default session → 0x31
7E0#021003CCCCCCCCCC   7E8#065003001901F4      extended session
7E0#03220413CCCCCCCC   7E8#05620413319C        12700 mV
7E0#03220413CCCCCCCC   7E8#056204133138        12600 mV, 350 ms later
7E0#03220414CCCCCCCC   7E8#046204141E          read 0x0414: 30 s (seeded at init)
7E0#042E04143CCCCCCC   7E8#037F2E33            write 0x0414 before SecurityAccess → 0x33
7E0#052E04133138CCCC   7E8#037F2E33            write 0x0413 before SecurityAccess → 0x33
   ... 27 01 / 27 02 ...                       SecurityAccess level 1 (seed and key not shown)
7E0#042E04143CCCCCCC   7E8#036E0414            write 0x0414 accepted
7E0#03220414CCCCCCCC   7E8#046204143C          read 0x0414: 60 s
7E0#052E04133138CCCC   7E8#037F2E31            write 0x0413 after SecurityAccess → 0x31
7E0#03220413CCCCCCCC   7E8#056204133183        12675 mV, value unchanged by the write
```

The read-only DID refuses a write in both states, with a different NRC. Before the
unlock, 0x33 comes from the service: 0x2E needs SecurityAccess level 1 whatever the DID
(`core/uds_access_table.c`). After it, 0x31 is the DID itself: it has no write access, so no
`did_write_*()` exists. The voltage keeps its triangle wave (12500-12700 mV, stepped by
the application), which is why the three reads differ.

### 7. Ask about the NRCs you saw

`explain_uds_error` on 0x33 (answering 0x2E) gives the right cause: the DID's security
level is above 0 and not unlocked, with a pointer not to lower `write_security_level` to
dodge it. On 0x31 (answering 0x22) it now says:

```
NRC 0x31 — requestOutOfRange (answering 0x22 ReadDataByIdentifier)

Cause in EDS:
  - [0x22] The DID is not supported in the active session: unknown, not readable, or the
    active session is below its min_session (EDS#465). ...

How to fix: Check the session first: is the active session at least the DID's or RID's
min_session (0x10 0x03 for extended)? Only then check that the ID is in
diagnostics_config.yaml and the firmware was rebuilt from it, ...
```

That is the cause here: 0x0413 is registered, and the default session is below its
`min_session`. (On v1.25.0 the same call answered "DID not found in the database", which
sent the reader to the wrong place, [EDS-toolchain#202](https://github.com/Xaloqi/EDS-toolchain/issues/202), fixed.)

## Known rough edges (EDS v1.26.1)

- **The scaffold is a starting point, not a patch.** Merge its `dids` entries by hand; its
  `can:` block is a reminder to fill in, not a value.
- **Regeneration replaces the `[APP HOOK]` bodies** in `generated/routine_handlers.c`. The
  CMake check stops the build if they are gone; restore the file or reapply the bodies
  (step 4).
- **Regenerating on a newer EDS changes more than your DIDs**, because the committed files
  come from an earlier version. Commit a regeneration of the unchanged YAML first.
- **`run_codegen`'s `stdout` names the licensee** ([EDS-toolchain#227](https://github.com/Xaloqi/EDS-toolchain/issues/227)).
  Strip the `License :` line before you share a transcript.
- **The free virtual ECU does not model your config.** It knows its own DIDs and creates
  others on write, so it cannot hold a read-only app-owned DID; use it for write gating
  and round trips on writable DIDs, and real CAN for the rest.
