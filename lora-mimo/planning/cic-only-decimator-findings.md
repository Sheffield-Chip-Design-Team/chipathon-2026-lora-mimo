# CIC-only Decimator: Findings

> **Status (2026-06-03, updated):** CIC-only IS the deployed solution. The FIR is dropped.
> See addendum below for the revised operating point and rationale.
>
> **Status (2026-05-31, original):** RTL simulation complete (SGE job 1102). CIC-only is NOT
> viable as a drop-in replacement for the primary 125 kHz LoRa mode at R=256.
> The FIR remains required. TDM sharing (`sd_fir_mac`) is still the correct area lever.

## Background

Motivation: could we eliminate the 13×16 multiplier in the SD decimator entirely by
dropping the CIC compensation FIR? Prior analysis (shift-add experiment, jobs 1088–1090)
showed Yosys already finds the optimal shift-add decomposition (only −3 k µm² saving).
This investigation tests the more radical option: no FIR at all.

RTL written: `rtl-test/sd_decimator_cic_only.v` — drop-in replacement for
`sd_decimator_combchain`, identical port list, all logic on `clk_32m`, zero multipliers.

Test: `rtl-test/syn_mimo_per_module/run_sqnr_cic_only.sh` — 4 decimation ratios ×
2 variants, tone at 0.4×Nyquist (worst-case droop), pass threshold 28 dB.

## RTL SQNR Results (SGE job 1102)

Tone at 0.4×Nyquist (near band edge). Signal amplitude and noise RMS from LS sine fit.

| R | BW | Variant | Sig amp (LSB) | Noise RMS (LSB) | SQNR I | SQNR Q | Pass? |
|---|---|---|---|---|---|---|---|
| 256 | 125 kHz | combchain | 46.0 | 0.81 | 32.1 dB | 41.8 dB | ✓ |
| 256 | 125 kHz | **cic_only** | 19.6 | 0.61 | **27.2 dB** | 36.5 dB | **✗** |
| 128 | 250 kHz | combchain | 45.4 | 0.42 | 37.7 dB | 41.7 dB | ✓ |
| 128 | 250 kHz | cic_only | 19.4 | 0.41 | **30.6 dB** | **30.3 dB** | **✓** |
| 64 | 500 kHz | combchain | 46.1 | 0.44 | 37.5 dB | 33.8 dB | ✓ |
| 64 | 500 kHz | **cic_only** | 19.5 | **4.56** | **9.6 dB** | **8.1 dB** | **✗** |
| 32 | 1 MS/s | combchain | 46.6 | 5.57 | 15.4 dB | 14.1 dB | ✗ |
| 32 | 1 MS/s | cic_only | 19.8 | 11.35 | 1.8 dB | 1.3 dB | ✗ |

Pass threshold: 28 dB. Note: combchain also fails at R=32 — low OSR, debug mode only.

## What the noise decomposition reveals

At R=256 and R=128: the noise floors are nearly identical between combchain and cic_only
(~0.4–0.8 LSB RMS). The SQNR difference (32.1 vs 27.2 dB at R=256) is **entirely from
the signal amplitude** — the FIR compensates the −7.3 dB CIC droop at 0.4×Nyquist,
boosting the signal from 19.6 to 46 LSB before 8-bit quantisation. Noise is dominated
by quantisation (theoretical ≈ 0.29 LSB RMS for ±0.5 LSB uniform distribution).

At R=64: cic_only noise is **4.56 LSB vs 0.44 LSB** for combchain — a 20 dB difference.
The noise at R=64 is dominated by **sigma-delta alias noise** folding back into the
[0, 250 kHz] passband. At R=64, the CIC has only N=3 orders of alias rejection and its
first null lands at 500 kHz (the Nyquist edge). Aliases from [300–500 kHz] enter with
only −18 dB to −40 dB attenuation. The 9-tap FIR reduces the effective alias noise
through its temporal averaging (the 9-sample window spans ~18 µs = ~12 cycles of the
strongest alias at 700 kHz). The cic_only module has no such filtering.

## Why the Python model was wrong

The earlier Python prediction (~34 dB for cic_only at all R) used floating-point CIC
simulation that does not model sigma-delta alias noise accurately. The Python model
applied the CIC as an ideal decimator and added only quantisation noise, missing the
real alias noise in the RTL at R=64.

**Lesson**: floating-point CIC models are inadequate for predicting alias noise at
low oversampling ratios. RTL simulation with a real ±1 sigma-delta stimulus is required.

## Conclusion

CIC-only is **not viable** for this design:

| Mode | Verdict | Reason |
|---|---|---|
| 125 kHz BW (R=256) | **FAIL** (27.2 dB, miss by 0.8 dB on I) | FIR compensates −7.3 dB CIC droop |
| 250 kHz BW (R=128) | PASS (30.3/30.6 dB) | Lower relative droop, low alias noise |
| 500 kHz BW (R=64) | **FAIL** (9.6 dB) | Sigma-delta alias noise, CIC alone insufficient |
| 1 MS/s (R=32) | **FAIL** (1.8 dB) | Low OSR, both variants fail |

The FIR serves two distinct roles:
1. **Signal boost**: compensates −7.3 dB CIC droop at band edge, increasing signal amplitude
   before 8-bit quantisation (≈ 2.4× = +7.5 dB), which matters for quantisation SNR.
2. **Alias noise suppression at low R**: the 9-tap temporal window reduces sigma-delta
   alias noise by ~20 dB at R=64 where CIC alias rejection is marginal.

## Impact on the TDM refactor plan

CIC-only saving would have been ~26 k µm² post-TDM (eliminating `sd_fir_mac` + 4×
`sd_fir_state`). This saving is now closed.

**The TDM refactor (`sd_fir_mac` + `sd_cic_chan`) remains the correct path.** One shared
FIR MAC for 4 channels is still required; it costs ~20 k µm² total (vs 380 k for 4×
instances today). The RTL is already written (`sd_fir_mac.v`, `sd_cic_chan.v`,
`sd_fir_state.v`); proceed to `sd_decimator_top.v` integration and verification.

## Addendum — 2026-06-03: CIC-only deployed at R=128

The original conclusion was based on a single-antenna digital-to-digital chain where the
downstream demodulator was on-chip and expected a specific IQ sample rate. That assumption
was wrong: **the LoRa demodulator is off-chip (SX1302)**. The ASIC output goes through
`sd_remod` which always produces a 32 MHz ΣΔ bitstream regardless of internal IQ rate.

This changes the operating point:

| Mode | R | decim_ratio | cic_only SQNR | Verdict |
|---|---|---|---|---|
| 125 kHz BW | 128 | 1 | 30.6 dB | **PASS** — 2 samples/chip; SX1302 re-filters |
| 250 kHz BW | 128 | 1 | 30.6 dB | **PASS** — 1 sample/chip; same hardware setting |
| 500 kHz BW | 64 | 2 | 9.6 dB | **NOT SUPPORTED** |

**Why R=128 works for 125 kHz BW:**
1. Both BW modes use the same `decim_ratio=1` (R=128) setting in firmware.
2. For 125 kHz BW, this gives 2 samples/chip at the CIC output — the sd_remod updates
   at 250 kHz and the SX1302 sees a denser ΣΔ stream, which the SX1302 channel filter
   integrates. The extra noise bandwidth (125–250 kHz) is rejected by the SX1302 filter.
3. The SX1257 analog IF filter (`RegRxBw`, reg 0x0D) already bandlimits the signal to
   the LoRa BW before the ΣΔ bitstream is generated — there is little out-of-band energy
   to alias in the first place.
4. The sd_remod→SX1302 path provides a third stage of filtering after the CIC.

**500 kHz BW not supported:** R=64 gives 9.6 dB SQNR — unusable. Lower R (R=32) is
worse (1.8 dB). This is a fundamental CIC alias rejection limit, not fixable by
oversampling. 500 kHz BW requires the FIR and is outside the system specification.

**FIR status:** Dropped from the design. `sd_decimator_cic_only.v` is now the production
decimator module. Area saving vs combchain: ~75 k µm² per instance (4 instances = ~300 k µm²).

**Firmware init:** Set reg 0x12 `decim_ratio = 2'b01` at startup for both 125 and 250 kHz BW.

## Files

| File | Purpose |
|---|---|
| `rtl-test/sd_decimator_cic_only.v` | CIC-only RTL (archived for reference; not used in design) |
| `rtl-test/syn_mimo_per_module/run_sqnr_cic_only.sh` | A/B SQNR test script |
| `rtl-test/syn_mimo_per_module/out_sqnr_cic_only/` | RTL output files + log (NFS only) |
