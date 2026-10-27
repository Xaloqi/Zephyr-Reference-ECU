The EDS MCP server (`tools/mcp_server.py`) ships in the EDS commercial toolchain and needs a Developer licence. It is not part of this repo or of the public EDS repo.

# An AI-assisted change, end to end

This page walks through one change to this ECU made from Claude Code with the EDS
MCP server: two new DIDs, from a YAML scaffold to a read on a real CAN bus. Every
output quoted here came from a real run on 2026-10-27 (EDS v1.25.0, NUCLEO-H753ZI).
The change itself is **not** in this repo; this page describes it so you can make
your own.

The MCP server gives the AI assistant four tools. None of them calls a model, and none
of them edits your files:

| Tool | Does |
|---|---|
| `generate_did_config` | Returns a `diagnostics_config.yaml` scaffold for the DIDs you describe |
| `validate_asil_b` | Runs `codegen.py --dry-run` at ASIL-B on YAML text and returns violations |
| `run_codegen` | Runs `codegen.py` on a config file and writes `generated/` |
| `explain_uds_error` | Explains an NRC in terms of the EDS check that returns it |

The assistant chooses the calls and makes the edits with its own file tools. A
person reviews each step. What the tools add is that mistakes get caught before
they reach C, and the run below shows several.

## Setup

1. **EDS at the version `west.yml` pins** (v1.25.0 at the time of writing), with the
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
  `src/bcm_state.c`.
- `BCM_InteriorLightTimeout_s` (0x0414, uint8): a calibration value, writable in the
  extended session.

### 1. Scaffold, then merge by hand

`generate_did_config` with both DIDs returns a complete scaffold: `metadata`, `timing`,
the two `dids` entries, and empty `dtcs`/`routines`. It is not a drop-in replacement
for this repo's file (no `schema_version`, no `can:` block). Copy only the two `dids`
entries into `diagnostics_config.yaml`, after `BCM_DoorCycleCount`.

### 2. Validate: the write-security rejection

For a writable DID the scaffold defaults `write_security_level` to 1. To see the check
working, the run deliberately set it to 0 on 0x0414. `validate_asil_b` rejected it:

```
[codegen] ERROR: SAFETY [HIGH-1]: dids[7] (id='0x0414') 'BCM_InteriorLightTimeout_s' has write access but write_security_level=0.  ASIL-B policy (ISO 26262-6) requires that every write-capable DID is protected by a SecurityAccess challenge. FIX: set write_security_level >= 1 in diagnostics_config.yaml for this DID. ...
```

With `write_security_level: 1` it returns `"valid": true`.

### 3. A read-only DID the app owns needs `write` (for now)

The app sets a DID's value only through the generated `did_write_<name>()`, and that
function exists only for DIDs with `write` access. So `BCM_BatteryVoltage_mV` follows
the same pattern as `BCM_DoorCycleCount`: `access: [read, write]`,
`write_security_level: 1`, so a tester without the key cannot overwrite it
([EDS-toolchain#201](https://github.com/Xaloqi/EDS-toolchain/issues/201)).

That exposed a second check. A writable DID in `min_session: "default"` is rejected,
because 0x2E is refused in the default session:

```
[codegen] ERROR: VALIDATION: dids[6]: DID has write access with min_session 'default', but WriteDataByIdentifier (0x2E) is only accepted in a non-default session (core/uds_access_table.c), so this DID can never be written. FIX: set min_session to 'extended' (or 'programming').
```

Both DIDs end up in `extended`:

```yaml
  - id:   "0x0413"
    name: "BCM_BatteryVoltage_mV"
    access:
      - read
      - write
    min_session:          "extended"
    read_security_level:  0
    write_security_level: 1
    data_length:          2

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

`run_codegen` writes all 11 files in `generated/`. With EDS v1.25.0, pass
`config_path` and `output_dir` **relative to `XALOQI_EDS_ROOT`** (for example
`../Zephyr-Reference-ECU/generated`). With absolute paths outside the EDS tree, the tool
writes the files and then returns an error
([EDS-toolchain#200](https://github.com/Xaloqi/EDS-toolchain/issues/200)).

Regenerating replaces `generated/routine_handlers.c`'s four `[APP HOOK]` bodies with
TODO stubs. The configure-time check catches it:

```
CMake Error at CMakeLists.txt:201 (message):
  [REF-ECU] ERROR: generated/routine_handlers.c no longer contains the [APP
  HOOK] markers.
```

Reapply the four bodies documented in `src/bcm_state.h`
(see [README](../README.md) "The one hand-edited `generated/` file"). This change
touched no routines: the regenerated file differed from a regeneration of the
unchanged YAML only in its timestamp. So restoring the committed file
(`git checkout -- generated/routine_handlers.c`) was the same as reapplying the bodies.
If you change routines, reapply the bodies by hand onto the new file.

### 5. The app side

In `src/bcm_state.c`, beside `bcm_push_door_cycle_count()`:

- push a simulated voltage on every monitor tick with `did_write_bcm_batteryvoltage_mv()`
  (a 12500–12700 mV triangle wave in the run);
- seed the timeout once at init with `did_write_bcm_interiorlighttimeout_s()` (30 s).

The NUCLEO build then succeeds with no warnings from `src/` or `generated/`.

### 6. Prove it

**Free virtual campaign.** Add the two DIDs to `campaigns/reference_bcm.yaml` (write,
read back, assert). The run passed 25/25 on `xaloqi-tester` 1.5.8. Do not put a
"write refused without SecurityAccess" step in the virtual job: the free virtual ECU
accepts the write ([TestLab#93](https://github.com/Xaloqi/TestLab/issues/93)), and
the step fails there:

```
[03/26] write_did(0x0414)  → FAIL  Expected NRC 0x33 but step produced a positive response
```

**Real CAN.** After flashing, the boot log reports `UDS stack ready: 9 DIDs  2 DTCs`.
From the host (CANable2, ECU on physical 0x7E0/0x7E8), frames as observed:

```
7E0#03220413CCCCCCCC   7E8#037F2231            read 0x0413, default session → 0x31
7E0#021003CCCCCCCCCC   7E8#065003001901F4      extended session
7E0#03220413CCCCCCCC   7E8#056204133138        12600 mV
7E0#03220413CCCCCCCC   7E8#0562041330D4        12500 mV, 350 ms later
7E0#03220414CCCCCCCC   7E8#046204141E          30 s
7E0#042E04143CCCCCCC   7E8#037F2E33            write before SecurityAccess → 0x33
   ... 27 01 / 27 02 ...                       SecurityAccess level 1
7E0#042E04143CCCCCCC   7E8#036E0414            write accepted
7E0#03220414CCCCCCCC   7E8#046204143C          60 s
```

### 7. Ask about the NRCs you saw

`explain_uds_error` on 0x33 gave the right cause (security level not unlocked). On 0x31
it gave "DID not found in the database", which is wrong here: 0x0413 is registered, and
the read was refused because the default session is below the DID's `min_session`.
Since EDS v1.20.0 ([EDS#465](https://github.com/Xaloqi/EDS/issues/465)), ReadDataByIdentifier returns 0x31 in that case
([EDS-toolchain#202](https://github.com/Xaloqi/EDS-toolchain/issues/202)). Check the
session before you regenerate anything.

## Known rough edges (EDS v1.25.0)

- `validate_asil_b` takes YAML as text, so the assistant re-types the file into the call.
  In the run the copy lost characters in comment lines on every call
  ([EDS-toolchain#199](https://github.com/Xaloqi/EDS-toolchain/issues/199)). Its
  `violations` list also includes a banner and a `WARN:` line
  ([EDS-toolchain#198](https://github.com/Xaloqi/EDS-toolchain/issues/198)). Treat
  only `[codegen] ERROR:` lines as violations.
- The rest are covered above: #200 (use relative paths), #201 (read-only app-owned DIDs),
  #202 (0x31), TestLab#93 (virtual write gating).
