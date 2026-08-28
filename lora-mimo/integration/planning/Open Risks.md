# Open Risks — Grouper ↔ Trouper chip-top integration

Register of known open risks specific to the **combined `chip_top`** (the
integration tree under `lora-mimo/integration/`), as distinct from each
project's own standalone risks. Grouper's own list is in
`integration/ip/grouper/…`; Trouper's is
`integration/ip/trouper/planning/Open Risks.md`. This is an index: each entry
is a short summary plus a pointer to the RTL / doc with the real detail.
Update in place as items close (move to a "Closed" section with the closing
evidence, don't delete) or as new ones are found.

**Priority key**

| Priority | Meaning |
|---|---|
| Critical | Blocks tapeout signoff as currently scoped |
| High | Does not block tapeout mechanically, but a real functional / performance / process failure mode if not addressed |
| Moderate | Affects a non-critical feature, a margin, or a documented-vs-verified mismatch; tapeout can proceed without it |
| Low | Tooling, documentation, or future-feature gap |
| Deferred | Accepted limitation with a known fix that is explicitly not being pursued; re-opened only when its stated trigger is met |

---

## High

### 1. CPU→peripheral AHB pipeline slice adds 2 HCLK cycles to every peripheral access — needs Grouper + Trouper sign-off

**What was changed.** A register slice (`ahb_conn_buff u_ahb_cpu_periph_pipe`)
was inserted between the picorv32 AHB master and `periph_ss` inside Grouper's
`digital_ss.sv`. This is a **local patch to the vendored Grouper checkout**
(`integration/ip/grouper`), not present on Grouper `dev`. It exists only to
break the long combinational CPU → `interconnect_ss` address-decode /
request-fanout cone, which is the **sole grouper-side setup violator** at
`max_ss_125C_3v00` (HCLK16 path group; startpoint
`u_cpu_ss.u_cpu.latched_branch`; ≈ −24 ns WNS pre-fix, ≈ 250 fanout endpoints
spread across UART / GPIO / SPI-slave / SPI-master-stub / QSPI-stub / RAM
control pins — measured in P&R job 5117). Without the slice, the combined
`chip_top` post-route SS setup WNS is **−23.95 ns**; the pre-slice reference
run (job 5069) was **−14.32 ns** with the slice present.

**The cost this entry is about.** `ahb_conn_buff` buffers **both** the request
and the response direction, so a peripheral transfer that is 1 cycle straight
through becomes **3 cycles** — i.e. **+2 HCLK (16 MHz) cycles, ≈ 125 ns, on
every peripheral access**:

- UART, GPIO, SPI slave, SPI master (stub), QSPI (stub), debug slot.
- **The external-peripheral window (`ext_ahb_m_if_*`) — i.e. the
  Grouper → Trouper register bridge (`integration/rtl/ahb_to_grp_bridge.v`).**
  Every CPU access that reaches Trouper's `reg_bank` over that bridge now
  carries the extra 2 HCLK cycles on top of the bridge's own CDC handshake
  latency.

RAM and ROM are **not** affected: on Grouper `dev` they are wired straight to
the CPU (`digital_ss` `rom_ss` / `ram_ss`), off the AHB fabric, so instruction
fetch and data load/store are unchanged.

**Risk.**
- Any firmware that busy-polls a peripheral status register (e.g. a UART
  TX-ready spin loop, or polling a Trouper register through the bridge) runs
  each poll 3× slower. Throughput of block transfers and interrupt-driven
  code is affected only marginally; tight polling loops are affected directly.
- Any host-visible or firmware timing budget that assumed single-cycle
  peripheral access — including the Grouper→Trouper bridge transaction rate
  and any "hold `GRP_WE`/`GRP_RE` ≥ N clocks" contract on the Trouper side
  (Trouper Open Risk #16 / #29) — must be re-checked against the new latency.
- picorv32's native memory interface tolerates arbitrary wait states, so this
  is expected to be **functionally** safe, but the CPI / throughput impact has
  **not been measured** and the slice has **not been simulated** (see #2).

**Sign-off required — both teams.**
- **Grouper team:** confirm the +2-cycle peripheral-access latency is
  acceptable for all Grouper firmware (bootloader, drivers, any polling
  loops), and decide whether to adopt the slice upstream (behind a
  parameter, default off) so it stops being a vendored-checkout patch.
- **Trouper team:** confirm the added latency on the `ext_ahb_m_if_*` /
  `ahb_to_grp_bridge` path does not break the register-bridge handshake
  contract, the `reg_bank` write/read timing, or any weight-commit / packet
  timing that depends on how fast Grouper can service the bridge.
- **Both:** agree whether −23.95 ns → −14.32 ns SS WNS (grouper-side violator
  population collapsed to the slice's single new path; residual is Trouper's
  own IQ_CLK32 decimator/remod cones) is the accepted operating point, or
  whether the per-slot alternative (slice only the slow slots inside
  `interconnect_ss`, sparing fast/nearby peripherals) is pursued instead.

**Alternative not taken.** Instead of one slice upstream of the whole fabric,
`ahb_conn_buff` could be instantiated per-slot inside `interconnect_ss` (the
pattern the old architecture used for the ROM/RAM slots) on only the slots
whose decode depth + placement distance actually violate — leaving
nearby/fast peripherals single-cycle. More RTL, more surgical; the natural
form if this is upstreamed.

**See:**
`integration/ip/grouper/hw/rtl/digital_ss.sv` (`u_ahb_cpu_periph_pipe`);
`integration/ip/grouper/hw/rtl/interconnect/ahb_conn_buff.sv` (module header —
the 0→1→3 cycle table);
`integration/ip/grouper/hw/rtl/interconnect_ss.sv` (the decode cone this
breaks);
`integration/rtl/ahb_to_grp_bridge.v` (the bridge that also eats the delay);
`lora-mimo/planning/grouper-trouper-landscape-floorplan-2026-08.md` Open
Item #11 (original analysis);
P&R jobs 5069 (with slice, −14.32 ns) and 5117 (without, −23.95 ns);
`spare/pd-landscape-integration-patches` branch of the Grouper repo (where the
be38558-era version of this patch is preserved);
Trouper Open Risks #16, #29 (Grouper/bridge register-bus contract).
**Found:** 2026-08-28 (re-porting Patch B onto Grouper `dev` for the combined
chip-top P&R).

---

## Moderate

### 3. Shared chip-top reset — decide whether Grouper and Trouper need independently resettable sections

**Current state.** `chip_top.v` drives **both** `u_grouper.async_rst_n` and
`u_trouper.RESETB` from a single `HRESETn` pad (chip_top.v lines ~53 / ~182).
One reset pad, both clock domains (16 MHz Grouper, 32 MHz Trouper) always
reset together. Functionally safe as-is; this entry is about a capability
gap, not a bug.

**The question.** Should the combined chip expose a **second reset pad** so
the two sections can be reset independently — e.g. reboot the Grouper CPU
without disturbing an in-progress Trouper capture, or clear Trouper's
datapath / PSRAM-buffer state without a full-chip reset? Each project's own
standalone pinout already has a dedicated reset (`ip/grouper/info.yaml`:
`rst_n`; Trouper: `RESETB`), so separate resets is the more faithful merge —
they were only fused here for convenience.

**What it would take (if pursued).**
- **+1 chip_top pad.** `RESETB` for Trouper on `#E` (SE, next to Trouper),
  Grouper keeps `HRESETn` on `#W`. `io_placement_landscape.cfg` has spare
  `#E` slots (`$4`) to absorb it. **Must be decided before pin freeze.**
- **`ahb_to_grp_bridge.v` dual-reset design — the real work.** The bridge
  spans both clock domains and currently resets all of its logic from
  `HRESETn`. With independent resets, one domain can be held in reset while
  the other runs; the req/ack handshake FSM must then have each half reset
  by its own domain's reset (`HCLK` side ← Grouper reset, `IQ_CLK` side ←
  Trouper reset) or it can deadlock / glitch on an asymmetric reset event.
  **Update (2026-08-28, F1, branch `timn/ahb-bridge-cdc-review`):** the
  bridge now has per-domain reset synchronizers (`hrst_n_sync` on `HCLK`,
  `iqrst_n_sync` on `IQ_CLK`; async assert / sync deassert). Both still take
  the single `HRESETn` today, but the split point for (b) is now one line
  each — feed `iqrst_n_*` from Trouper's reset and `hrst_n_*` from Grouper's.
  This closes the *metastable-reset-release* bug (which existed even with the
  shared reset) independently of the independent-reset decision.
- **`chip_top_dual_clock.sdc`** — a second async reset net needs the same
  `set_false_path` / input-delay treatment the shared one has.

**Alternative — no second pad.** Keep the single hard-reset pad and add a
firmware-visible **soft-reset bit per section** on the register path
(Trouper `reg_bank` may already have one; Grouper could gate `async_rst_n`
with a CSR). Gives independent section reset without spending a pad, at the
cost of not being able to recover a wedged section that can't be reached
over its own bus.

**Decision needed.** Either (a) accept the shared hard reset and rely on
per-section soft-reset CSRs, or (b) add the second reset pad before pin
freeze — and then resolve the bridge dual-reset design.

**See:** `integration/rtl/chip_top.v` (`HRESETn` fanout);
`integration/rtl/ahb_to_grp_bridge.v` (single-reset FSM spanning both
domains); `integration/pd/chip_top_dual_clock.sdc`;
`integration/pd/io_placement_landscape.README.md` (`#E` spare slots);
`integration/ip/grouper/info.yaml` (`rst_n`); Trouper pinout (`RESETB`).
**Found:** 2026-08-28 (combined-pinout P&R bring-up; deferred in favour of
keeping the shared reset for the first combined run).

### 4. 25 MHz Grouper clock accepted for the test chip on an unverified corner argument

**Decision (2026-08-28).** The combined chip is targeted to run Grouper's
`HCLK` at **25 MHz** on the test chip (up from the 16 MHz baseline). P&R job
5131 (full flow, DRC/LVS clean) at 25 MHz MEETS setup at `nom_tt_025C_3v30`
with **+9.48 ns** slack and at `min_ff_n40C_3v60` with +18.94 ns; it fails
only at `max_ss_125C_3v00` (**−15.19 ns**, worst path now Grouper's
`u_cpu_ss.ram_sel_r` → SRAM `GWEN`/`CEN` decode cone — see
`lora-mimo/planning/grouper-trouper-landscape-floorplan-2026-08.md` item 20).

**Why this is a risk.** The feasibility call rests on the `ss_125C_3v00`
failure being an artifact of two pessimisms the bench will not see — 125 °C
derating and a 3.0 V undervolt of 5 V-rated `gf180mcu_fd_sc_mcu7t5v0` cells —
and on the intended bench point being ~25 °C / 3.5 V. **There is no
`ss_025C_3v50` Liberty corner** and OpenSTA does not interpolate, so this has
**not been measured**. The 25 MHz `ram_sel_r` → SRAM path is period-limited
with a ~18 MHz SS ceiling; if the real slow-silicon-at-bench margin is
thinner than the nominal-corner number and item-18 voltage-proxy trend
suggest, 25 MHz may not be safe on slow parts.

**Action.** Run a proxy STA at the closest lower-temp / higher-voltage
corner (item 18 method: reuse the routed `.odb`, swap only the std-cell
Liberty), or have an `ss_025C_3v50`-ish corner characterised, before the
25 MHz target is treated as closed. Not touched by the CPU→periph pipeline
slice (#1) — RAM is off the AHB fabric.
**See:** planning doc item 20 (job 5131 full result + the feasibility
argument); item 18 (voltage-proxy precedent); `integration/pd/chip_top_dual_clock.sdc`
(`create_clock -name HCLK25 -period 40.0`; renamed from HCLK16 / 62.5 on the
2026-08-28 retarget, branch `timn/ahb-bridge-cdc-review`).
**Found:** 2026-08-28.

### 5. `ahb_to_grp_bridge` captures GRP read data on a fixed delay, not on `GRP_READY`

`ahb_to_grp_bridge.v` asserts `GRP_WE`/`GRP_RE` for `HOLD_CYCLES` (default 6)
`IQ_CLK` edges and then latches `GRP_RDATA` into `response_rdata` when the
hold counter reaches zero. `GRP_READY` is a port but is explicitly **not**
used as a completion condition (see the `_unused_grp_ready` note at the
bottom of the module) — the legacy bridge did not make it load-bearing and
Trouper currently drives it as a combinational status.

**Risk:** correctness depends on `HOLD_CYCLES` ≥ Trouper's worst-case GRP
read latency, *including* `reg_bank`'s internal every-other-cycle enable and
any future added pipeline stage on that read path. If Trouper's read latency
ever grows past the hold window, reads return stale/!ready data silently —
no protocol error, no timeout.

**Action.** Either qualify `response_rdata` capture and `SRC_WAIT_ACK`
completion with `GRP_READY` (turning the fixed hold into a bounded
worst-case), or add an explicit assertion + directed test that pins
Trouper's GRP read latency at ≤ `HOLD_CYCLES` and fails CI if it regresses.
Fold into any chip-top TB once one exists.
**See:** `integration/rtl/ahb_to_grp_bridge.v` (F4 note in the header;
`hold_count` / `_unused_grp_ready`); Trouper `reg_bank` read timing;
Trouper Open Risks #16/#29 (GRP bus contract).
**Found:** 2026-08-28 (CDC review, branch `timn/ahb-bridge-cdc-review`).

### 6. `ahb_to_grp_bridge` has no error or timeout path — a stuck GRP access hangs Grouper

`HRESP` is hardwired to `OKAY`. There is no address range check and no
transaction timeout: if a GRP access never completes (Trouper wedged, clock
stopped, `HOLD`-window assumption from #5 violated in a way that stalls the
FSM), the bridge holds `HREADY` low **forever** and the picorv32 AHB master
blocks on that transfer with no recovery short of a full-chip reset.

**Risk:** a single wedged peripheral access takes the whole Grouper CPU down
with it, with no software-visible fault to trap on.

**Action.** Add a coarse transaction watchdog in the `HCLK` domain
(`SRC_WAIT_ACK` timeout → `HRESP=ERROR`, `HREADY=1`, drop the request) so
firmware gets a bus fault instead of a hang; optionally an out-of-range
`HADDR` → `ERROR` decode. Coordinate with Grouper on whether its bus fault
is actually trapped (Trouper Open Risks #49 point 2 flags the same gap on
the other adapter).
**See:** `integration/rtl/ahb_to_grp_bridge.v` (F5 note; `assign HRESP =
1'b0`); `integration/ip/grouper/hw/rtl/cpu_ss.sv` (fault handling).
**Found:** 2026-08-28 (CDC review, branch `timn/ahb-bridge-cdc-review`).

---

## Low

### 2. CPU→periph pipeline slice is lint-clean but has never been simulated

`u_ahb_cpu_periph_pipe` (see #1) passes `fusesoc lint` / Verilator
`--lint-only` on the full SoC elaboration and has been confirmed in P&R to
eliminate the target SS violator, but **no functional or protocol simulation**
has been run with it in place. `ahb_conn_buff` is the same module already used
elsewhere in the fabric, which lowers the risk of an AHB-protocol bug, but the
piped CPU↔periph path specifically — wait-state handling on back-to-back
transfers, the response-capture timing note in the module header
(`ahb_rom`/`ahb_ram`-style slaves that drive read-enable from `~HWRITE`), and
the interaction with `interconnect_ss`'s own registered response mux — is
unverified.

**Action.** Run `grouper_soc_tb` / `grouper_soc_directed` (or the chip-top TB
once it exists) with the slice in place before this is treated as closed; fold
the result into #1's sign-off.
**See:** #1; `integration/ip/grouper/hw/rtl/interconnect/ahb_conn_buff.sv`
header; `integration/ip/grouper/CLAUDE.md` (TB targets).
**Found:** 2026-08-28.

### 7. `ahb_to_grp_bridge` accepts `HTRANS=SEQ` and ignores `HBURST` — MMIO-only by assumption

`ahb_transfer` in `ahb_to_grp_bridge.v` is true for `NONSEQ` **and** `SEQ`,
`HBURST` is not a port, and `HTRANS` is only inspected in `SRC_IDLE`. So a
master wait state / `BUSY` in the data phase is not honoured, and a burst is
handled as a sequence of independent single beats, each paying the full
request→hold→ack CDC latency (~6 `IQ_CLK` + handshake per beat). Fine for the
register bus this bridge actually serves — Grouper's `ext_ahb_m_if` MMIO
path issues single byte transfers — but it is an unstated assumption.

**Action.** No functional fix needed for the current use. Either gate
`ahb_transfer` on `HBURST == SINGLE` and error otherwise, or leave as-is with
the header comment (F6) making the single-beat-MMIO assumption explicit.
Revisit only if anything ever puts a bursting master on this port.
**See:** `integration/rtl/ahb_to_grp_bridge.v` (F6 note; `ahb_transfer`).
**Found:** 2026-08-28 (CDC review, branch `timn/ahb-bridge-cdc-review`).
