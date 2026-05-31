# Extension: TDM+FIR Decimator (sd_decimator_top)

> **Priority:** Post-tapeout or late-stage if die area allows.
> Implement only after `mimo_rx_top` P&R closes cleanly and utilisation
> leaves ≥ 86 k µm² of headroom.

## What this buys

| Metric | CIC-only (current) | TDM+FIR | Delta |
|---|---|---|---|
| Decimator area | 300 k µm² | ~214 k µm² | **−86 k µm²** |
| LoRa sensitivity | −3.15 dB droop | Full spec | **+3.15 dB** |
| Multiplier | None | 1× shared 13×16 | 1 multiplier |
| RTL complexity | Simple | Moderate | — |

The −86 k µm² saving is ~3 % of total chip area. The +3.15 dB sensitivity
recovery is equivalent to half a spreading factor of link budget.

## Trigger condition

Run this extension if, after `mimo_rx_top` P&R:

1. DRC/LVS pass and timing closes at 32 MHz (SS/125 °C/3.0 V)
2. Floorplan utilisation is ≤ 55 % (DRT density wall is 60–70 %; need margin)
3. At least 4 days remain before tapeout freeze

If any condition is not met, ship with CIC-only.

## RTL status — what already exists

All sub-modules are written and individually verified:

| Module | File | Status |
|---|---|---|
| `sd_cic_chan` | `rtl-test/sd_cic_chan.v` | Written; SQNR verified (job 1102 baseline) |
| `sd_fir_state` | `rtl-test/sd_fir_state.v` | Written |
| `sd_fir_mac` | `rtl-test/sd_fir_mac.v` | Written; round-robin scheduler included |
| `sd_decimator_top` | `rtl-test/sd_decimator_top.v` | **Missing — needs wiring** |

## Implementation steps

### 1. Write `sd_decimator_top.v` (1 day)

Wire the three sub-modules per `planning/sd_decimator-tdm-refactor.md §Phase 1`:

```
sd_decimator_top
├── sd_cic_chan  ×4   (clk_32m; outputs cic_out_i/q + cic_valid)
└── sd_fir_shared ×1  (clk_16m; owns FIR delay lines + MAC)
    ├── sd_fir_state  ×4  (9-tap delay line per channel)
    └── sd_fir_mac    ×1  (coeff ROM, 13×16 mul, acc, scheduler)
```

Port list and CDC notes are in `planning/sd_decimator-tdm-refactor.md §Interface`.

### 2. Verify (1 day)

Run existing test scripts with `sd_decimator_top` as DUT:

```bash
# A/B SQNR vs sd_decimator_cic_only baseline (threshold 28 dB, all R)
# Adapt run_sqnr_cic_only.sh: swap DUT to sd_decimator_top, rename swap file

# dsp-chain loopback (tb_dsp_chain_loopback_probe.v)
# Accept ≤ 24 clk_16m cycle latency shift vs cic_only baseline
```

Pass gate: all 8 channel×ratio combinations ≥ 28 dB, loopback PASS.

### 3. Swap into `mimo_rx_top.v` (30 min)

Replace the 4× `sd_decimator_cic_only` block (lines ~102–137) with:

```verilog
sd_decimator_top u_dec_top (
    .clk_32m(clk), .clk_16m(clk), .rst_n(rst_n),
    .iq_in_i(IQ_DATA_I), .iq_in_q(IQ_DATA_Q),
    .decim_ratio(rb_decim_ratio),
    .iq_out_i_0(_dec_i0), .iq_out_i_1(_dec_i1),
    .iq_out_i_2(_dec_i2), .iq_out_i_3(_dec_i3),
    .iq_out_q_0(_dec_q0), .iq_out_q_1(_dec_q1),
    .iq_out_q_2(_dec_q2), .iq_out_q_3(_dec_q3),
    .iq_valid(iq_valid)
);
```

`clk_16m` is tied to `clk` (same 32 MHz) — this was the existing arrangement.
The downstream `dc_removal` onwards is unchanged.

### 4. Re-run `mimo_rx_top` synthesis + P&R (3–4 hours)

Confirm:
- Area ≤ 214 k µm² for decimator sub-tree
- Timing closes (same constraints as cic_only run)
- No new DRT violations

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| DRT congestion from shared FIR routing | Low (only 1 multiplier) | Keep FP_CORE_UTIL ≤ 55 % |
| CDC glitch on clk_16m = clk_32m tie | None | CDC is designed for this; `fir_strobe_ext` handles alignment |
| `sd_fir_mac` scheduler bug | Low (unit-tested) | Run 4-channel loopback first |

## Reference

- Detailed design: `planning/sd_decimator-tdm-refactor.md`
- CIC-only decision rationale: `planning/cic-only-decimator-findings.md`
- Synthesis baseline: SGE job 1104 (cic_only 74,940 µm²/instance)
