# MRC Combiner

RX path stage 8. See [DSP Flow](../DSP%20Flow.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Time-domain, sample-by-sample combining of 4 antenna inputs using weight vector W computed by the Weight Generation block. PicoRV32 may optionally override the shadow bank in software mode, but the combiner must not depend on firmware for baseline RX. Supports two modes:

**MRC:** inner product — scalar output
```
y[n] = (w^H · x[n]) >> 1   // 4 complex MACs → int32 → arithmetic right-shift 1 (÷2) → int8
```

**Passthrough (bypass):** single-antenna direct route, W ignored
```
y[n] = x[bypass_sel][n]   // 1 antenna, int8 direct — no ÷2 applied
```
`bypass_sel` is the index of the lowest-numbered antenna with its `ANTENNA_EN` bit set, decoded from the `bypass_ant` input.

W is produced by the Weight Generation block (hardware FSM or PicoRV32 software path) after `training_done` from the Training Accumulator. Until current-packet W is valid, the combiner must not output zeros; it falls back to the selected bypass antenna so the SX1302 continues seeing a valid single-antenna LoRa stream. In passthrough mode W registers are not read.

---

## Interface

| Port | Direction | Width | Rate | Description |
| --- | --- | --- | --- | --- |
| `x_i[3:0]` | in | 4×8 signed | f_s | I from decimators (4 antennas) |
| `x_q[3:0]` | in | 4×8 signed | f_s | Q from decimators |
| `x_valid` | in | 1 | f_s | Sample strobe |
| `W_re[3:0]` | in | 4×16 signed | static | W vector real — from W register bank |
| `W_im[3:0]` | in | 4×16 signed | static | W vector imaginary |
| `W_valid` | in | 1 | static | Current-packet W has been atomically committed to the active W bank |
| `mode` | in | 1 | static | 0 = MRC; 1 = passthrough |
| `bypass_ant[1:0]` | in | 2 | static | Index (0–3) of antenna to route in passthrough mode; decoded from ANTENNA_EN by control logic |
| `clk_32m` | in | — | 32 MHz | Master clock |
| `rst_n` | in | — | — | Active-low reset |
| `y_i` | out | 8 signed | f_s | Combined I output (MRC: int32 ÷2 → int8; bypass: direct int8) |
| `y_q` | out | 8 signed | f_s | Combined Q output (MRC: int32 ÷2 → int8; bypass: direct int8) |
| `y_valid` | out | 1 | f_s | Sample strobe |

---

## Parameters

| Parameter | Value | Notes |
| --- | --- | --- |
| W precision | int16 Q1.15 | Written by hardware weight generation or PicoRV32 software override |
| x precision | 8-bit signed | From decimators |
| Accumulator | int32 | 8×16 = 24-bit product; 4 complex MACs → max 2²⁴ < 2³¹; int32 sufficient with 7 bits of headroom |
| MACs per sample | 4 complex = 8 real MACs | |
| Output | int8 signed | MRC: int32 accumulator arithmetic right-shifted 1 (÷2), saturated to int8; bypass: direct int8 from antenna (no ÷2) |

---

## Flat-fading assumption and antenna spacing

The scalar combining scheme (`y[n] = w^H · x[n]`) assumes each branch's channel `h_j` is a **complex scalar** — a single amplitude and phase. The weight `w_j = conj(Z_j)` then applies an exact phase correction for branch j, regardless of how large that phase is. Phase differences between branches can be anywhere from 0 to 2π (at 868 MHz with half-wavelength spacing the direct-path phase difference alone spans π radians), and the scalar weight handles all of these correctly.

This assumption holds as long as the **inter-branch delay spread** is small relative to one sample period (8 µs at 125 kHz / 2.4 km equivalent path length). If delay spread exceeds one sample, `h_j` is multi-tap and a scalar weight can only align one tap — combining gain degrades.

**Antenna spacing constraint:** the four antennas must be physically close enough that inter-branch delays are well below one sample. For this design, antennas are co-located on the same board or enclosure at separations comparable to the wavelength (~34 cm at 868 MHz, so a few centimetres to a few tens of centimetres). At these separations, the geometric delay difference between branches is at most a few nanoseconds — orders of magnitude below 8 µs. The flat-fading, scalar-weight model is valid.

Distributed antenna deployments (antennas hundreds of metres apart) are outside the design intent and would require per-branch equalisation rather than a scalar weight.

---

## Implementation notes

**MAC structure.** Each complex MAC: `acc_re += W_re×x_i − W_im×x_q`, `acc_im += W_re×x_q + W_im×x_i`. Four complex MACs per sample.

**Output headroom.** MRC coherently adds branch amplitudes. The hardware weight path now uses shift-MRC: weights are proportional to `conj(H_j)` with a shared conservative right shift and branch-count headroom. The combiner still applies a fixed ÷2 guard shift, then an optional `COMB_POST_GAIN` left shift before saturating to int8. Reset value `COMB_POST_GAIN=0` is conservative; firmware may increase it after observing output headroom. Bypass output is int8 directly, preserving the full per-branch amplitude. The AGC owns the per-branch level constraint (−3 dBFS max per branch); see AGC headroom constraint. Int8 saturation is a safety net for AGC settling transients only.

**Accumulator saturation.** After the fixed ÷2 guard shift and optional post-combine gain, saturate to int8 bounds (±127) — do not allow 2's-complement wrap. This provides a safety net for AGC settling transients or unexpected strong signals, but should not be the normal operating condition.

### COMB_POST_GAIN policy

`COMB_POST_GAIN` is a packet-to-packet amplitude recovery knob for shift-MRC. It is intentionally outside weight generation: weight generation stays conservative and timing-friendly, while firmware/host can recover output level when the combined stream has headroom.

Register behavior:

```
y_guarded = mrc_accumulator >>> 1
y_out     = sat8(y_guarded <<< COMB_POST_GAIN_SHIFT)
```

Reset/default is `0`. A conservative firmware policy is:

1. Start every unknown channel/gain state at `COMB_POST_GAIN=0`.
2. Observe the combined int8 stream peak over a packet or diagnostic window.
3. If any I/Q component is near saturation, keep or return to `0`.
4. Otherwise choose the largest shift such that `observed_peak << shift <= 90`.
5. Apply the new shift for subsequent packets, not mid-packet.

The `90` target preserves roughly -3 dBFS headroom for the ΣΔ re-modulator. Larger values may be useful in lab characterization, but should be treated as an explicit tradeoff against clipping margin.

**Output latency and y_valid handshake.** The combiner propagates `x_valid` through its fixed-depth pipeline and asserts `y_valid` exactly P clock cycles later, where P is a constant determined by the RTL implementation (TBD — typically 1–4 cycles). The ΣΔ re-modulator downstream must consume samples on `y_valid` rather than assuming a fixed offset from `x_valid`. P must be recorded in the RTL as a parameter and exposed in the block's timing documentation once implementation begins. This removes the need to pre-specify latency in the spec and makes the interface self-describing.

**Live output state.** Weight generation (hardware FSM or firmware) runs in parallel with the live decimator-to-remod stream. The combiner output policy is:

```
NO_W / ACQUIRING:   y = x[bypass_sel]          // int8 direct, no ÷2
W_VALID, MODE=0:    y = (w^H · x) >> 1         // MRC: int32 ÷2 → int8
MODE=1 passthrough: y = x[bypass_sel]          // int8 direct, no ÷2
```

This makes the first packet recoverable as a single-antenna packet if W arrives late, and prevents mid-preamble silence from breaking SX1302 detection.

**W register read timing.** W registers must be double-buffered. The hardware weight path or PicoRV32 software path writes `W_SHADOW`, then asserts a one-cycle commit strobe after all words are written. Hardware copies `W_SHADOW` to `W_ACTIVE` atomically and sets `W_valid`. The combiner reads only `W_ACTIVE`, so firmware writes cannot glitch live MACs. If W is invalidated mid-packet, keep using the last committed `W_ACTIVE` until firmware explicitly clears `W_valid` or changes mode.

**No-glitch switching.** `W_ACTIVE`, `ACTIVE_MODE`, and `ACTIVE_ANTENNA_EN` must update only when the receiver is idle between packets. Host writes to `MODE` or `ANTENNA_EN` update shadow configuration during an active packet and commit at the next idle boundary. If current-packet W is not ready, stay in bypass for that packet rather than switching mid-symbol or at a payload boundary.

**Degenerate case.** When only 1 antenna is enabled via `ANTENNA_EN`, W is a scalar — trivially computed by firmware. Combiner still works; unused antenna inputs are zero.

**Passthrough MUX.** In passthrough mode, a 4:1 MUX on `bypass_ant` selects the raw int8 sample from one decimator and drives it directly to `y` — no sign-extension, no ÷2. The MAC array is clock-gated. This MUX sits at the output stage of the combiner block so the bypass path has identical clocking and output register timing as the combining paths.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| MRC, 4 equal antennas | Pre-load MRC W; inject 4-channel sine | Output power ≈ 4× single antenna (6 dB) |
| MRC, degenerate (1 antenna) | Set ANTENNA_EN=0001 | Output = single-antenna SNR |
| No current W | Start packet with `W_valid=0` | Output follows `bypass_ant`; REMOD_A receives a valid single-antenna stream |
| W commit | Write W shadow then commit | `W_ACTIVE` changes atomically; no partially-written W appears at output |
| W update mid-packet | Write new W via AHB-Lite during combining | Old W used until commit; no glitch |
| Safe switch | Assert W commit while packet is active | W activation is deferred until the next idle boundary |
| Mode write mid-packet | Host writes MODE/ANTENNA_EN during active packet | `ACTIVE_MODE`/`ACTIVE_ANTENNA_EN` unchanged until next idle boundary |
| Passthrough, ant0 selected | MODE=2, ANTENNA_EN=0001, inject sine on ant0, zeros on ant1–3 | y = x_ant0 (int8 direct); identical to decimator output, no amplitude reduction |
| Passthrough, ant2 selected | MODE=2, ANTENNA_EN=0100 | y[0] tracks ant2 exactly; ant0/1/3 ignored |
| Passthrough vs MRC gain | Same signal, compare MODE=0 and MODE=2 output power | MRC output ≈ 6 dB higher (4 equal antennas) |
| Latency constant | f_s input, MRC mode | `y_valid` asserts exactly P cycles after `x_valid` for every sample; P is fixed and does not vary with mode or W value |

---

## Area reduction analysis — 2026-05-31

**Current implementation:** `mrc_combiner.v`, 121 k µm² (Yosys, gf180mcu_as_sc_mcu7t3v3, TT/25°C/3.3 V).

### Area breakdown

| Component | Approx. µm² | Notes |
|---|---|---|
| 4× 16×8 multipliers (combinatorial) | ~70 k | Core of `prod_i_next` / `prod_q_next` |
| Variable `post_gain_shift` barrel shift (33-bit, 3-bit select) | ~15 k | Lines 74–75 in RTL |
| 26-bit accumulators + adders | ~20 k | `acc_i`, `acc_q`, final pipeline register |
| MUX pipeline registers + FSM control | ~15 k | 8 dedicated W/X latch regs, state machine |

The 4 multipliers are the minimum needed to compute one complex multiply in a single clock cycle:
`prod_i = w_re×x_i − w_im×x_q` and `prod_q = w_re×x_q + w_im×x_i`.
The block already TDMs across 4 antennas (7 states per sample, 7 cycles used of 256-cycle budget at R=256).

### Cut options

**Option A — Serialise I and Q (4 muls → 2 muls, ~−35 k, low effort)**

Compute I and Q in sequential sub-cycles instead of in parallel:
- Sub-step 1: `w_re×x_i` and `w_re×x_q` → latch both
- Sub-step 2: `w_im×x_q` and `w_im×x_i` → form `prod_i = p1−p2`, `prod_q = p3+p4`

2 cycles per antenna × 4 antennas = 8 cycles total (vs 6 currently). Budget remains 256 cycles.
Saves 2 of the 4 multipliers. Straightforward RTL change; no algorithmic impact.
**Estimated result: ~86 k µm².**

**Option B — Reduce weight precision 16-bit → 12-bit (~−30 k, medium effort)**

12×8 multipliers instead of 16×8. Weight quantisation noise is negligible for LoRa:
12-bit gives 72 dB SNR on weights; channel estimation noise dominates well before that.
Requires `weight_gen.v` output ports narrowed to 12-bit and all downstream register map widths adjusted.
Can be combined with Option A.
**Estimated result (A+B): ~60 k µm².**

**Option C — Fix `post_gain_shift` at synthesis time (~−12 k, trivial)**

The 3-bit variable barrel shift (COMB_POST_GAIN) synthesises to an expensive 33-bit MUX tree.
If the gain is fixed at compile time (e.g., always 2), this is free wiring.
Only worthwhile if runtime adjustment of post-combine gain is not needed.
**Estimated result (C alone): ~109 k µm².**

**Option D — CORDIC rotation (~−50 k net, high effort)**

Replace all 4 multipliers with a CORDIC rotator (shifts + adds only).
~16 iterations for 12-bit precision; 32 CORDIC cycles × 4 antennas = 128 cycles — fits in budget.
Eliminates ~70 k of multiplier area; adds ~20 k of CORDIC control/shift logic.
Most aggressive option; requires careful fixed-point validation of combining gain.
**Estimated result: ~70 k µm².**

**Option E — Share multiplier with `training_acc` (~−35 k from training_acc side)**

`training_acc` uses 4× 8×8 multipliers during preamble only. `mrc_combiner` uses 4× 16×8 during data phase.
These operate at non-overlapping times. A shared 16×8 unit (with narrower mode for training) would
eliminate `training_acc`'s dedicated multipliers. Saves area on the `training_acc` side rather than here.
Moderate complexity; cross-module interface change.

### Recommendation

**Best near-term cut: A + C** — serialise I/Q and fix post_gain_shift. Combined saving ~47 k, effort is low,
no algorithmic risk. Brings mrc_combiner from 121 k to ~74 k µm².

**Further reduction:** Add B (12-bit weights) for a total of ~60 k — roughly half the current area — at
the cost of a weight_gen port change. Still no algorithmic degradation for LoRa.

**Not recommended for this tapeout:** D (CORDIC) — high implementation risk relative to the saving.

---

## Related blocks

- [ΣΔ Decimator](ΣΔ%20Decimator.md) — 8-bit signed input
- [PicoRV32 Integration](PicoRV32%20Integration.md) — optional software override path via AHB-Lite
- [ΣΔ Re-modulator](ΣΔ%20Re-modulator.md) — consumes int8 input; combiner int16 output is arithmetic right-shifted 1 (÷2) and saturated to int8 at the remod input boundary
- [Register Map](../Register%20Map.md) — `W` matrix at `0x90`–`0xAF`
- [DSP Flow](../DSP%20Flow.md)
