# Eclipse OpenSOVD CDA interop — fixture mechanics and scope

## Why two entries exist only for this

**Two disclosed CDA-interop-only entries**, same honesty policy as EDS's
own precedent: DID `0xF100` ("Identification", fixed value `0xFF0000`)
selects the CDA's own shipped `FLXC1000.mdd` fixture's `Boot_Variant` —
without it the CDA has no SecurityAccess service to route to at all.
Routine `0x1001` ("SelfTest") exists only because SOVD resolves
`/operations/<name>` against whatever ODX database the CDA has loaded,
not against anything this ECU reports — so matching the fixture's own ID
is the only way to reach RoutineControl through it, rather than this
ECU's own `DoorLockAll`/`WindowCalibrate`, which the fixture doesn't know
about. Neither carries any application logic; see
`diagnostics_config.yaml`'s own comments. A custom ODX fixture describing
this ECU's own real identity would be the cleaner alternative — it isn't
available, for the same reason EDS's own demo documents (the CDA's
PDX-to-MDD converter isn't publicly distributable).

## What this absorbs

`scripts/demo_sovd_cda_real_hw.sh` absorbs
[Xaloqi/EDS's own BUILD-1 capability](https://github.com/Xaloqi/EDS/blob/main/scripts/demo_can_sovd_cda_interop.sh)
(the script and this capability are otherwise identical) retargeted at
this repo's real hardware instead of EDS's `native_sim` + `vxcan`.

## What this does not prove

- **DoIP** — the CDA discovers DoIP gateways only by UDP Vehicle
  Identification, which EDS has never implemented
  ([`EDS#392`](https://github.com/Xaloqi/EDS/issues/392)).
- The pytest/CAPL half of EDS's codegen working without a commercial
  licence — it does not.
- This ECU's own door-ajar/window-stall application logic *through
  SOVD* — the CDA's fixture has no route to those at all, so SOVD can't
  reach them. See [Run it on a board](../README.md#run-it-on-a-board)
  for how those were verified instead (raw ISO-TP, this repo's own
  tooling, no CDA involved).
