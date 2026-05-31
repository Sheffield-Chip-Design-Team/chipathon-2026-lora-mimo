# sd_decimator TDM-share refactor plan

> **Status (2026-05-31): SUPERSEDED for primary design.**
> mimo_rx_top.v now uses `sd_decimator_cic_only ×4` (300 k µm², zero multipliers).
> This refactor is kept as an **optional extension** if area/schedule permit.
> It would save a further ~86 k µm² vs CIC-only and restore full sensitivity
> (+3.15 dB). Implement only after all other blocks are P&R-complete.
>
> Original status: combchain stage-drop validated (SQNR + dsp-chain loopback
> bit-exact). Baseline was 189 k µm²/instance = ~759 k chip.
>
> **Shift-add experiment (2026-05-30, jobs 1088–1090):** replacing the 13×16
> variable multiply with explicit CSD shift-add trees saved only **−3 k µm²**
> per instance (189,665 → 186,572). yosys+abc already decomposes the variable
> multiplier to a cell-optimal adder tree; the explicit shift-add form actually
> uses more maj3 carry cells (+81). Conclusion: leave the multiply as-is;
> the saving comes from TDM sharing (1× FIR instead of 4×), not from the
> multiply implementation. `sd_decimator_shiftadd.v` is archived but not
> landed. TDM refactor is underway — `sd_cic_chan.v` (step 1) in progress.
>
> **CIC-only experiment (2026-05-31, SGE job 1102):** dropping the FIR entirely
> fails the 28 dB SQNR floor at R=256 (primary 125 kHz mode: 27.2 dB, miss by
> 0.8 dB) and fails badly at R=64 (9.6 dB, sigma-delta alias noise dominates).
> The FIR is required for both passband compensation and alias noise suppression.
> Full analysis: `planning/cic-only-decimator-findings.md`. TDM refactor is
> the only viable area lever on the decimator.

## Goal

Reduce the **815 k µm² (32 % of `mimo_rx_top`)** spent on 4× `sd_decimator`
without changing system behaviour (NR=4 MRC is required; antenna count is
fixed). Target saving: ~120–160 k µm² (5–6 % of chip).

## Constraint that drives the plan

- 32 MHz is the **only** sample-rate domain available on GF180MCU 3.3V
  ([[picorv32-clock-decision]] — SS corner won't close above 16 MHz comb;
  32 MHz already tight for the 1-bit input rate).
- Therefore the **CIC integrators MUST stay per-channel**. Folding 4 ch
  through one integrator would need 128 MHz.
- Per-channel state (delay registers in CIC combs and FIR delay lines)
  also stays per-channel — TDM only shares *arithmetic operators*, not state.

## What stays per-channel (×4 instances)

Every 1-bit input requires its own state regardless of TDM:

| Block | Width × count | Why per-channel |
|---|---|---|
| CIC integrator regs (`intg_i1/2/3`, `intg_q1/2/3`) | 26 b × 6 = 156 flops | clocked every 32 MHz cycle |
| CIC integrator adders | 6× 26-bit add/sub | same |
| CIC comb delay regs (`comb_*_d`) | 26 b × 6 = 156 flops | hold last `cic_strobe` sample |
| FIR delay line (`fir_dl_i/q`) | 12 b × 18 = 216 flops | 9-tap shift register |
| Local control / strobe pipe | small | small |

Total per-channel residue: ~530 flops × 4 ch ≈ ~80–90 k µm² each → **~350 k µm²
permanently per-channel**. This is the floor — the unfoldable part.

## What becomes shared (×1 instance, TDM)

Operators that run only at the *decimated* rate (≤ 1 MHz at R=31, far slower
at R=255). At 32 MHz a 4 ch × 3 stage round-robin (12 cycles) fits inside
even the smallest 32-cycle window.

| Shared block | What it replaces | Saving (est.) |
|---|---|---|
| 1× comb subtractor (26 b) | 6× per inst × 4 inst − 1 = 23 subtractors | ~25–30 k |
| 1× normalisation shifter | 4× barrel | ~5 k |
| FIR MAC (13 b × 16 b mul + 32 b acc + round/sat) | 4× FIR datapath | ~80–110 k |
| FIR control FSM + coeff ROM | 4× | ~10 k |
| Strobe scheduler | new | – (~5 k cost) |
| **Subtotal saving** | | **~120–160 k µm²** |

## Proposed module split

```
sd_decimator_top
├── sd_cic_integ    ×4  (per-channel, 32 MHz, integrators only)
├── sd_cic_comb     ×4  (per-channel state: comb delay regs)
│                       (combinational mux drives shared comb_op)
├── sd_comb_op      ×1  (shared 26-bit subtractor + shift, 32 MHz)
├── sd_fir_state    ×4  (per-channel: 9-tap delay line + ping-pong sample reg)
└── sd_fir_mac      ×1  (shared coeff ROM + mul + acc + sat, 16 MHz)
```

## TDM scheduling — does it fit?

**Comb path (32 MHz, decimated rate):**
- Tightest case: R=31 → strobe every 32 cycles
- Need 4 ch × 3 stages = 12 ops per strobe interval
- 12 << 32 ✓ Plenty of slack even with overhead

**FIR path (16 MHz):**
- Output rate fixed at 125 kS/s → strobe every 128 clk_16m cycles
- Per channel: 6 busy cycles (current design)
- TDM 4 ch: 24 cycles per strobe interval
- 24 << 128 ✓ Plenty

Worst-case latency: 12 cycles @ 32 MHz (~375 ns) on comb + 24 cycles @ 16 MHz
(~1.5 µs) on FIR. All channels still output before the next decimated sample
at any R setting.

## Interface (top wrapper, drop-in replacement for current `sd_decimator` ×4)

```verilog
module sd_decimator_top (
    input  wire        clk_32m,
    input  wire        clk_16m,
    input  wire        rst_n,
    input  wire [3:0]  iq_in_i,        // 4 channels, 1 bit each
    input  wire [3:0]  iq_in_q,
    input  wire [1:0]  decim_ratio,
    output wire signed [7:0] iq_out_i [0:3],
    output wire signed [7:0] iq_out_q [0:3],
    output wire        iq_valid        // common (all 4 ch outputs aligned)
);
```

Top-of-design swap: replace the `generate for` block at
`mimo_rx_top.v:108–123` with one `sd_decimator_top u_dec_top (...)`
instantiation. Downstream `dc_removal` already takes all 4 channels — no
change there.

## Verification plan

1. **Bit-exact regression**: existing `sd_decimator` testbench → wrap in
   parallel-4 harness. Re-run with the new module; outputs must match
   sample-for-sample.
2. **SQNR**: same DSP-chain testbench at OSR 32, 64, 128, 256 across all
   4 channels driven with independent noise. Compare against pre-refactor
   reference within 0.5 dB.
3. **Synthesis area check**: re-run `run_synth_hier.sh` on
   `mimo_rx_top` post-refactor. Confirm saving ≥ 120 k µm².
4. **Timing**: same constraints (16 MHz comb / 32 MHz integ). The shared
   FIR MAC is 13×16 single-cycle at 16 MHz — same as today, same critical
   path budget.

## Stretch: combine with CIC bit-width slim (independent change)

Reducing CIC integrator width 26 → 22 bits adds another ~30–50 k µm² and is
orthogonal to TDM. Requires SQNR analysis at OSR=256 (worst case for growth)
but is a one-file localparam change — do it as a follow-up sweep, not
bundled with this refactor.

## Risks

- **Strobe-scheduler complexity**: a small FSM driving the shared comb op
  and FIR MAC. Easy to get off-by-one; 4 ch × 3 stages = 12-state ROM is
  trivial to formally verify.
- **Routing congestion**: 4 → 1 sharing concentrates wires from per-channel
  state into the shared op. With FP_CORE_UTIL ≤ 50 % this is fine; if
  packing gets tight, the DRT-0073 wall ([[drt-density-wall]]) could bite.
- **Net saving below estimate**: the shared FIR MAC area depends on how
  much of `signed_mul24`/MAC the synthesiser collapses. If pre-refactor
  combiner already factored the multiplier hard, the delta will be at the
  low end. Worst plausible saving: ~80 k µm². Best plausible: ~180 k.

## Decision gate before RTL work

This is a real refactor (~2-3 days) and the saving is 5–6 % of chip. Before
committing, weigh against alternatives:

| Lever | Saving | Effort |
|---|---|---|
| **This TDM refactor** | ~120–160 k µm² | medium (RTL + verify) |
| CIC width 26→22 (no TDM) | ~30–50 k µm² | small (localparam + SQNR) |
| Share FIR mul only (smaller refactor) | ~80 k µm² | small-medium |
| `weight_gen` time-share (rank #4 block, 186 k local) | up to ~140 k µm² | unknown (haven't audited) |
| `sc_detector.signed_mul24_pipe` fold | ~75 k µm² | medium |

Recommend pairing this with CIC-width slim (orthogonal, cheap) for ~150–200 k
combined. Alternatively, audit `weight_gen` for similar leverage first —
similar area, possibly easier to fold.

---

## Phase 1 detailed design: shared FIR MAC

### Module boundaries

Three new modules replace the 4× `sd_decimator_combchain` instances:

```
sd_decimator_top            (top wrapper — drop-in for the generate-for loop)
├── sd_cic_chan  ×4         (all per-channel 32 MHz state: integrators + comb)
└── sd_fir_shared  ×1      (shared FIR: state ×4 + 1× MAC engine + scheduler)
    ├── sd_fir_state  ×4   (9-tap delay line per ch; tap-pair mux out to MAC)
    └── sd_fir_mac    ×1   (coeff ROM, 13×16 mul, 32-bit acc, round/sat, FSM)
```

`sd_cic_chan` is essentially the current module's 32 MHz section cut at the
`shifted_i/q` + `strobe_pipe` outputs. `sd_fir_shared` owns the 16 MHz
domain entirely.

---

### `sd_cic_chan` port list

```verilog
module sd_cic_chan (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire        iq_in_i,
    input  wire        iq_in_q,
    input  wire [1:0]  decim_ratio,
    output wire signed [11:0] cic_out_i,   // = shifted_i[11:0]
    output wire signed [11:0] cic_out_q,
    output wire        cic_valid           // = strobe_pipe (1-cycle pulse)
);
```

State inside: 6× intg regs (26 b), 6× comb_d regs (26 b), 2× intg_lat regs,
2× shifted regs, decim_cnt, norm_shift, cic_strobe, strobe_pipe.
Per-channel flop budget: ~530 flops × 26/12 mix ≈ 59 k µm² each.

---

### `sd_fir_state` port list (per-channel, 16 MHz)

```verilog
module sd_fir_state (
    input  wire        clk_16m,
    input  wire        rst_n,
    // From CIC (crosses 32→16; data stable ≥ 128 cycles after valid pulse)
    input  wire signed [11:0] cic_in_i,
    input  wire signed [11:0] cic_in_q,
    input  wire        load_strobe,         // one clk_16m pulse per CIC output
    // From scheduler: which tap pair to expose this cycle
    input  wire [2:0]  tap_sel,
    // To MAC: the symmetry-summed pair for the selected tap
    output reg  signed [12:0] tap_pair_i,
    output reg  signed [12:0] tap_pair_q
);
```

State inside: `fir_dl_i[0:8]` and `fir_dl_q[0:8]` (12 b × 9 × 2 = 216 flops).
The delay-line shift happens on `load_strobe`; tap-pair mux is the same as
the current design (5 cases, symmetric pairs).
Per-channel: 216 flops × ~6.5 µm² ≈ 1.4 k µm² each → 5.6 k total.

---

### `sd_fir_mac` port list (shared, 16 MHz)

```verilog
module sd_fir_mac (
    input  wire        clk_16m,
    input  wire        rst_n,
    // Handshake from CIC channels
    input  wire [3:0]  ch_valid,            // one-hot, from 4× sd_cic_chan
    // Per-channel tap pair (driven by sd_fir_state)
    input  wire signed [12:0] tap_i [0:3],
    input  wire signed [12:0] tap_q [0:3],
    // To each sd_fir_state: which channel + which tap to expose
    output reg  [1:0]  ch_sel,             // active channel
    output reg  [2:0]  tap_sel,            // active tap (0..4)
    // Outputs: one per channel, registered when accumulation completes
    output reg  signed [7:0] out_i [0:3],
    output reg  signed [7:0] out_q [0:3],
    output reg  [3:0]  out_valid           // one-hot, one clk_16m pulse per ch
);
```

---

### Scheduler FSM

The FIR MAC processes all 4 channels sequentially. Each channel needs 6
busy cycles (5 multiply-accumulate + 1 output/round, matching the current
pipeline). Total: 24 cycles per strobe interval.

At R=255 (125 kS/s output), each strobe fires every 128 `clk_16m` cycles.
24 cycles << 128 — no scheduling conflict is possible at any R setting.

```
State: {ch[1:0], tap[2:0]}

IDLE
  on ch_valid[0]: ch=0, tap=0  (load dl[0], start mac)
  on ch_valid[1] (& !ch_valid[0]): ch=1, tap=0
  priority to lowest-index pending channel

ch=N, tap=0..4  (5 cycles)
  tap==4: advance to ch=N, tap=5

ch=N, tap=5  (output/round cycle)
  write out_i[N], out_q[N]; assert out_valid[N]
  if next ch pending: ch=(N+1)%4, tap=0
  else: IDLE
```

Pipeline note: the shared MAC retains the same 2-register pipeline
(pair_r → mul_r → acc). Per-channel accumulators (`fir_acc_i/q[0:3]`)
live in `sd_fir_mac` and are updated only when the in-flight `ch_sel`
matches their index.

```
Shared pipeline registers (not replicated):
  fir_pair_i_r, fir_pair_q_r   13 b × 2
  fir_coeff_r                  16 b
  fir_mul_i_r,  fir_mul_q_r    29 b × 2
  fir_pair_valid_r, fir_mul_valid_r

Per-channel accumulator registers (×4, small):
  fir_acc_i[0:3], fir_acc_q[0:3]   32 b × 4 × 2 = 256 b total
  out_i[0:3], out_q[0:3]            8 b × 4 × 2  =  64 b total
```

---

### State inventory — per-channel vs shared

| Portion | Current (4×) | Refactored | Delta |
|---|---|---|---|
| CIC per-channel (intg + comb regs + arith) | 4 × ~89 k = 356 k | 4 × ~89 k = 356 k | 0 |
| FIR delay line (9-tap, per-ch) | 4 × ~1.5 k = 6 k | 4 × ~1.5 k = 6 k | 0 |
| FIR MAC (13×16 mul + acc + coeff ROM) | 4 × ~95 k = 380 k | 1 × ~20 k = 20 k | **−360 k** |
| FIR FSM + per-ch acc + output regs | 4 × ~4 k = 16 k | ~3 k shared + ~2 k new state | **−11 k** |
| Scheduler (new) | 0 | ~3 k | +3 k |
| **Total** | **~758 k** | **~386 k** | **≈ −370 k µm²** |

Conservative estimate (assuming synthesiser already partially shares the
multiplier across instances): **−250 k µm²**. Best case: **−370 k**.
This is 10–15 % of chip — a meaningful tapeout lever.

---

### Top-level integration (`mimo_rx_top.v`)

Current generate-for block (lines 108–123):

```verilog
genvar g;
generate
    for (g = 0; g < 4; g = g + 1) begin : gen_dec
        sd_decimator u_dec (
            .clk_32m(clk_32m), .clk_16m(clk_16m), .rst_n(rst_n),
            .iq_in_i(sd_in_i[g]), .iq_in_q(sd_in_q[g]),
            .decim_ratio(decim_ratio),
            .iq_out_i(dec_out_i[g]), .iq_out_q(dec_out_q[g]),
            .iq_valid(dec_valid[g])
        );
    end
endgenerate
```

Replace with:

```verilog
sd_decimator_top u_dec_top (
    .clk_32m    (clk_32m),
    .clk_16m    (clk_16m),
    .rst_n      (rst_n),
    .iq_in_i    (sd_in_i),          // wire [3:0]
    .iq_in_q    (sd_in_q),          // wire [3:0]
    .decim_ratio(decim_ratio),
    .iq_out_i   (dec_out_i),        // wire signed [7:0] [0:3]
    .iq_out_q   (dec_out_q),
    .iq_valid   (dec_valid[0])      // common strobe; tie dec_valid[3:1] = dec_valid[0]
);
```

`dc_removal` already accepts all 4 channels — no change needed downstream.

---

### Verification gates

1. **SQNR A/B** (extend `run_sqnr_combchain.sh`): wrap `sd_decimator_top`
   in a 4-parallel harness; drive all 4 channels with the same tone; check
   per-channel SQNR ≥ 28 dB, delta from combchain baseline < 0.5 dB.

2. **dsp-chain loopback** (`tb_dsp_chain_loopback_probe.v`): replace
   `sd_decimator` instantiation with `sd_decimator_top`; all 6 PASS
   milestones must fire bit-exact. Accept ≤ 1 strobe-interval latency shift
   (24 clk_16m cycles) vs combchain baseline.

3. **Post-refactor area** (`run_synth_hier.sh` on `mimo_rx_top`): confirm
   `sd_decimator_top` area ≤ 450 k µm² (saving ≥ 250 k vs 756 k baseline).

4. **Timing** (same constraints as `run_sta_combchain.sh`): 32 MHz integrator
   domain unchanged; FIR MAC at 16 MHz unchanged critical path (13×16 in
   62.5 ns). Scheduler FSM is pure 16 MHz, trivially meets timing.

---

### Implementation order

1. `sd_cic_chan.v` — extract 32 MHz section from `sd_decimator_combchain.v`
   verbatim; verify SQNR unchanged (drive `sd_fir_state` directly).
2. `sd_fir_state.v` — extract delay-line + tap-pair mux; add `tap_sel` input;
   verify tap-pair output matches current design sample-for-sample.
3. `sd_fir_mac.v` — shared engine with round-robin FSM; unit-test with 1
   channel first (must be identical to current FIR section), then 4-channel.
4. `sd_decimator_top.v` — wire everything up; run SQNR + dsp-chain tests.
5. Swap into `mimo_rx_top.v` and run full synthesis to confirm area delta.
