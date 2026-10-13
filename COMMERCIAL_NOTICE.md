# Commercial Notice

This file makes the licence boundary explicit for this repository. It is
short because this repo itself has no commercial boundary of its own — the
boundary belongs to the two projects it depends on.

---

## This repository (the application layer)

Everything in `src/`, `diagnostics_config.yaml`, `generated/`, `boards/`,
`campaigns/`, `tests/`, and the build files is **licensed Apache-2.0**
(`LICENSE` at repo root) — use it freely, including in proprietary projects,
no obligation to release your own source.

## What it depends on

### Xaloqi EDS (the diagnostics stack, pulled in as a west module)

EDS is dual-licensed: GPL-2.0 for the runtime (`core/`, `transport/`,
`config/`, `platform/`), commercial for the code generator's templates
(`tools/templates/`) and the automated test generator (`tools/testgen.py`).
Full terms: [`Xaloqi/EDS`'s own `COMMERCIAL_NOTICE.md`](https://github.com/Xaloqi/EDS/blob/main/COMMERCIAL_NOTICE.md).

**What that means here, concretely:**

| You want to... | Licence needed |
|---|---|
| Clone this repo, build it, run it on `native_sim` | **None.** `generated/` is pre-committed — the same mechanism EDS's own examples use (see EDS's `COMMERCIAL_NOTICE.md`: "Examples ship their generated C"). |
| Edit `diagnostics_config.yaml` and regenerate `generated/` yourself | **A commercial EDS licence** (Developer or Professional, at [xaloqi.com](https://xaloqi.com)) — `tools/codegen.py` is public and readable, but the Jinja2 templates it needs are the paid deliverable. |
| Ship this ECU's firmware as proprietary, closed-source | **A commercial EDS licence** — GPL-2.0 otherwise requires releasing your firmware's source. |
| Generate the pytest/CAPL test suite alongside the C (`tools/testgen.py`) | **A commercial EDS licence** — this half of codegen has no free path. |

### xaloqi-tester (the free campaign runner used in `campaigns/`)

Apache-2.0, no licence required. `campaigns/reference_bcm.yaml` runs against
the free `--virtual` tier exactly as shipped — see that file's own header
comment for exactly what the free tier does and does not simulate. Real
CAN/DoIP transports are a separate, paid tier (`xaloqi-tester-pro`) — not
needed for anything in this phase.

---

## Questions

EDS licensing: contact@xaloqi.com. Issues with this repo: open a GitHub
issue here.
