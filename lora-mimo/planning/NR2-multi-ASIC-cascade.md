# NR=2 Multi-ASIC Cascade — Architecture and Lock-Detect Scheme

**Status:** Design exploration (2026-06-03)

## Area Target

**2.0 mm² die — achievable target.**

| Parameter | Value |
|-----------|-------|
| CPU | PicoRV32 |
| Decimator | CIC-only (no FIR compensation) |
| NR per chip | 2 |
| Stdcell | ~1.11 mm² |
| SRAM macros | 0.41 mm² (2× OCD 1024×8 CPU + 1× OCD 512×8 frontend buf) |
| Routable area | ~1.59 mm² (stdcell at 70% utilisation) |
| **Die core** | **~2.0 mm²** |

Assumes 70% stdcell utilisation in the non-macro routable area, which requires careful macro placement and floorplan optimisation but is a realistic tapeout target. Effective density at 70% util is ~76% — above the current safe default of 55–60% but achievable with targeted congestion relief and layer adjustment.

### NR=4 comparison at the same 70% assumption

| Config | Stdcell | Macros | Die (70% util) |
|--------|---------|--------|----------------|
| NR=2 CIC-only PicoRV32 | 1.11 mm² | 0.41 mm² | **2.00 mm²** |
| NR=4 CIC-only PicoRV32 | 1.43 mm² | 0.52 mm² | **2.56 mm²** |

NR=4 costs 0.56 mm² more per die (+28%) but is a single-chip solution. The system-level silicon is very different:

| System | Dies | Total silicon |
|--------|------|--------------|
| NR=4 single chip | 1 × 2.56 mm² | **2.56 mm²** |
| NR=2 cascade (×3 identical) | 3 × 2.00 mm² | **5.99 mm²** |

NR=4 is 2.4× more silicon-efficient for the whole system, eliminates inter-chip lock synchronisation, removes re-modulator SQNR accumulation risk, and gives true 4-branch MRC instead of hierarchical combining. The cascade is only justified if the submission has a hard per-die area limit below 2.56 mm².

---

---

## Motivation

The ΣΔ decimator is the largest block per antenna branch. Moving from NR=4 to NR=2 per ASIC halves the decimator count and the frontend buffer SRAM, at the cost of splitting the receive chain across multiple chips. A 3-chip cascade (2 feeder chips + 1 combiner chip) recovers the effective NR=4 combining gain while keeping each ASIC's analog and decimation complexity manageable.

---

## Topology

All three chips are **identical**. The cascade is formed by routing each chip's ΣΔ re-modulator output (a 1-bit 32 MHz bitstream) to the next chip's ΣΔ decimator input — the same interface the chip uses with the SX1257. No custom inter-chip protocol is needed.

```
  Chip A                         Chip B
  ┌─────────────────────┐        ┌─────────────────────┐
  │  Ant 0, Ant 1       │        │  Ant 2, Ant 3       │
  │  2× ΣΔ decimator    │        │  2× ΣΔ decimator    │
  │  SC detect (NR=1)   │        │  SC detect (NR=1)   │
  │  Training accum     │        │  Training accum     │
  │  NR=2 weight gen    │        │  NR=2 weight gen    │
  │  NR=2 MRC combiner  │        │  NR=2 MRC combiner  │
  │  ΣΔ re-modulator    │        │  ΣΔ re-modulator    │
  │  PicoRV32 + regs    │        │  PicoRV32 + regs    │
  └────────┬────────────┘        └──────────┬──────────┘
           │ 1-bit ΣΔ bitstream             │ 1-bit ΣΔ bitstream
           │ at 32 MHz (remod_out)          │ at 32 MHz (remod_out)
           └──────────────┬─────────────────┘
                          ▼
                   Chip C (identical die)
                   ┌──────────────────────────────────┐
                   │  iq_in[0] ← chip A remod_out     │
                   │  iq_in[1] ← chip B remod_out     │
                   │  2× ΣΔ decimator                 │
                   │  SC detect (NR=1, on iq_in[0])   │
                   │  Training accum (NR=2)            │
                   │  NR=2 weight gen                 │
                   │  NR=2 MRC combiner               │
                   │  ΣΔ re-modulator                 │
                   │  PicoRV32 + regs                 │
                   └──────────────────────────────────┘
                          │
                          ▼
                   SX1302 combined stream
```

Chip C's SC detector locks on the re-modulated preamble arriving from chips A and B. Because chips A and B are themselves locked and timing-aligned (via the OR-lock scheme), chip C sees two preamble-aligned ΣΔ streams and locks independently without further inter-chip signalling. The OR-lock mechanism is only needed between chips A and B — not between chip C and the feeders.

---

## Inter-Chip Lock Detect — OR-Lock Scheme

### Problem

Chips A and B run independent SC detectors. Their `sc_lock` edges and `timing_ref` values will differ by noise jitter — typically 0–2 samples at SF6, potentially up to 1 symbol in weak-signal conditions. Chip C needs all 4 branches to start training from the same symbol boundary.

### Scheme

Each chip exposes two pins:

| Pin | Direction | Description |
|-----|-----------|-------------|
| `sc_lock_out` | output | asserts when this chip's SC detector naturally locks |
| `sc_lock_in` | input | OR of all chips' `sc_lock_out` lines |

Internally: `effective_lock = sc_lock_detected || sc_lock_in`

When `effective_lock` rises and the chip has not already latched `timing_ref`, it latches the current sample counter as `timing_ref`. Chip C gets `sc_lock_in` from the same OR, so all three chips synchronise to the same packet-detect event.

On the PCB: `sc_lock_out` from A and B wired to each other's `sc_lock_in` and to Chip C's `sc_lock_in`. Open-drain drivers with a pull-up give a wired-OR with no contention.

### Why timing_ref is still valid after a forced lock

**Critical requirement: inter-chip clock and reset coherence.**

All three chips must share:
1. The same 32 MHz clock source (XTB/TCXO shared clock tree — already required for 4-channel coherence per the SX1257 clock architecture)
2. A reset deassertion driven from the same flip-flop on the host PCB

Under these conditions, all decimator sample counters run in absolute lockstep. When Chip B's SC detector is forced to assert `effective_lock` because Chip A fired first, Chip B latches its own sample counter — which is identical to Chip A's counter at that instant. Both `timing_ref` values therefore point to the same absolute sample index, and Chip C sees perfectly aligned inter-chip IQ streams.

**If one chip's signal is too weak to naturally lock**, the forced lock still gives the correct symbol boundary because the sample counters are synchronous. That chip's channel estimate `Z_j` will be noise-dominated and MRC will assign it a low weight — the correct outcome.

### Risk: reset skew

If `rst_n` deassertion reaches two chips on different clock cycles, their `decim_cnt` starts from different phases and the sample counters are permanently offset. This is not detectable at runtime (no symptom other than corrupted MRC weights).

**Mitigation:** Route `rst_n` from a single registered output on the host MCU/FPGA with matched trace lengths to all three chips.

---

## Inter-Chip Interface

The inter-chip interface is the same 1-bit 32 MHz ΣΔ bitstream that every chip already uses with the SX1257 — `remod_out` on chip A/B connects to `iq_in` on chip C. No additional protocol or digital bus is required.

The only extra inter-chip signals are the OR-lock wires (between A and B only):

| Signal | Type | Between |
|--------|------|---------|
| `sc_lock_out` | 1-bit open-drain | A ↔ B (wired OR) |
| 32 MHz clock | shared from TCXO XTB | A, B, C all driven from same source |
| `rst_n` | registered output from host, matched traces | A, B, C |

Chip C derives its own `sc_lock` and `timing_ref` by running its SC detector on the incoming re-modulated streams from A and B. No lock signal needs to be forwarded from A/B to C.

---

## Frontend Buffer SRAM

The SC detector is already NR=1 (single-channel, antenna 0 only — Round 2 reduction, job 1138). The delay buffer it needs for stored-phase SC detection is:

```
256 I samples × 8-bit  +  256 Q samples × 8-bit  =  512 × 8-bit
```

This fits exactly in **one 512×8 OCD SRAM macro** per chip. The second antenna in the NR=2 pair contributes to the training accumulator (which cross-correlates without a delay buffer) but not to SC detection.

Result: one SRAM macro per chip, well-understood timing, no multi-macro routing complexity.

---

## PSRAM Replay and Why Lock Sync Is Critical

Each chip has its own PSRAM (APS6404L) which continuously buffers its 2-antenna IQ streams. After lock and weight computation, the chip replays the buffered packet from `timing_ref` through the MRC combiner and ΣΔ re-modulator. This has two important consequences for the cascade:

**Training window is not a problem for chip C.** Chip C stores the incoming re-modulated streams from chips A and B into its own PSRAM as they arrive in real time. Even though chip C locks later than A and B (after A/B's full DSP pipeline has processed the preamble and started replaying), chip C's PSRAM already holds the preamble from the moment the streams arrived. Chip C's training accumulator replays from its own PSRAM starting at its own `timing_ref` and sees the full preamble.

**Lock sync is critical because of PSRAM replay alignment.** When chips A and B replay from their PSRAMs, each starts from its own `timing_ref`. If chip A's `timing_ref` is sample 1000 and chip B's is sample 1003, the re-modulated streams arriving at chip C are offset by 3 samples. Chip C's training accumulator cross-correlates both streams against each other — a 3-sample misalignment produces wrong channel estimates and degraded or failed combining.

The OR-lock scheme ensures chips A and B latch the **same absolute sample index** as `timing_ref` (they share a synchronous clock and sample counter). A and B then replay from the same offset, and the streams reaching chip C are sample-aligned.

This is the primary reason lock sync is required — not preamble detection timing, but PSRAM replay alignment feeding chip C's combining stage.

---

## Combining Gain and Suboptimality

The cascade performs **hierarchical MRC**, not true 4-branch MRC:

- Level 1: Chip A computes `w_A · [h₀, h₁]ᵀ → y_A`; Chip B computes `w_B · [h₂, h₃]ᵀ → y_B`
- Level 2: Chip C computes `w_C · [y_A, y_B]ᵀ → y_out`

This is optimal when all 4 branches have equal SNR. With unequal branch SNRs (one antenna shadowed within a pair), the level-1 combiner suppresses the weak branch before chip C can compensate. The penalty relative to true 4-branch MRC is typically 0.5–1.5 dB for mild imbalance, up to ~2 dB in extreme cases. For co-located antennas in typical outdoor LoRa deployments this is acceptable.

---

## Re-Modulator SQNR Accumulation

Chip C receives a signal that has already passed through one ΣΔ re-modulation → decimation cycle. The 1st-order ΣΔ re-modulator contributes ~34 dB SQNR (measured at R=256, A=0.35). Two cascaded re-mod/decim stages will degrade the effective noise floor at chip C's combiner output.

**Required action before committing to 3-chip topology:** Simulate the cascaded path — inject a known IQ signal into chip A/B, apply the re-modulator model, feed into chip C's decimator model, measure SNR at chip C's combiner output. Confirm the SNR margin is still adequate for the target LoRa sensitivity.

---

## Open Items

1. **Re-modulator SQNR cascade simulation.** See above. This is the primary risk of the cascaded-identical-chip topology.

2. **Hierarchical MRC suboptimality simulation.** Simulate NR=4 true MRC vs 3-chip hierarchical MRC over a sweep of per-branch SNR imbalance. Confirm the worst-case penalty is within the link budget.

3. **Fallback to single-chip NR=2 operation.** If one feeder chip fails, chip C sees only one valid input. It degrades to single-antenna passthrough (bypass mode) or NR=1 operation, not NR=2. This is a graceful degradation: chip C's ANTENNA_EN and bypass logic handle it without firmware intervention.

---

## Related

- [ΣΔ Decimator](blocks/ΣΔ%20Decimator.md) — inter-instance coherence requirements
- [SC Detector](blocks/SC%20Detector.md) — sc_lock and timing_ref interface
- [Weight Generation](blocks/Weight%20Generation.md) — NR parameter, Z_j inputs
- [SX1257 Clock Architecture](../memory/sx1257-clock-architecture.md) — XTB shared TCXO rationale
