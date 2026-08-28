#!/usr/bin/env python3
"""
iq_stimulus.py -- prepare a real measured IQ capture as 1-bit sigma-delta
stimulus for tb_chip_top.v STIM=iq (T5).

Reuses Trouper's own capture front-end (cocotb/tests/iq_capture.py): load a
baseband capture, resample to the 32 MS/s chip rate, fan out to NR=4 branches
through per-antenna channels + a shared AWGN floor, then 1st-order sigma-delta
modulate I and Q of each branch to 0/1 -- exactly the stimulus
sd_decimator_poly expects, and bit-for-bit the same modelling
test_capture_playback.py drives over cocotb.

Emits into OUT (default cwd):
  iq_stim.hex       one hex byte per IQ_CLK: {q3,q2,q1,q0,i3,i2,i1,i0}
                    (q3 = branch-3 Q bit ... i0 = branch-0 I bit), for
                    $readmemh into the tb's `reg [7:0] iq_stim[]`.
  iq_stim.cfg.vh    `define IQ_SF / IQ_BWSEL / IQ_NSAMP for the tb.

Env knobs:
  IQ_FILE   capture path (.iq uint8 I/Q, or .npy complex)   [1_packet_mingain.iq]
  IQ_SR     capture sample rate in S/s                      [1000000]
  IQ_SF     spreading factor 7..12                          [7]
  IQ_BW     bandwidth kHz: 125 or 250                       [125]
  IQ_START  first capture sample to use                     [0]
  IQ_NSAMP  capture samples to use (at IQ_SR)               [60000]
  IQ_SNRDB  shared AWGN SNR in dB ("" = noiseless)          [""]
  IQ_CHAN   "awgn" (flat) | "rayleigh"                      [awgn]
  IQ_PHASES per-antenna carrier phase deg, comma list       [0,35,70,110]
  IQ_GAINS  per-antenna large-scale gain dB, comma list     [0,-2,-4,-6]
  IQ_SEED   RNG seed for channel + AWGN                     [0]

The IQ_PHASES / IQ_GAINS defaults give the 4 branches DISTINCT flat-fading
channels so Z is a non-degenerate Hermitian matrix (equal phases + gains make
every branch see the same signal -> every Z entry identical -> the eigenvector
test is trivial). Set them equal only to check the degenerate corner.
  TROUPER_ROOT / DESIGN_ROOT   trouper repo root (for iq_capture + models)
"""
import os
import sys
import pathlib

import numpy as np

TROOT = os.environ.get("TROUPER_ROOT") or os.environ.get("DESIGN_ROOT") or "/trouper"
sys.path.insert(0, str(pathlib.Path(TROOT) / "cocotb" / "tests"))
import iq_capture as ic  # noqa: E402

OUT = pathlib.Path(os.environ.get("OUT", "."))
IQ_MAX = 1 << 22  # must match tb_chip_top.v localparam IQ_MAX


def _envf(name, default):
    v = os.environ.get(name, "")
    return float(v) if str(v).strip() else default


def _envi(name, default):
    v = os.environ.get(name, "")
    return int(float(v)) if str(v).strip() else default


def main():
    path   = os.environ.get("IQ_FILE") or str(
        pathlib.Path(TROOT) / "sim" / "examples" / "1_packet_mingain.iq")
    sr_in  = _envf("IQ_SR", 1_000_000.0)
    sf     = _envi("IQ_SF", 7)
    bw_khz = _envi("IQ_BW", 125)
    start  = _envi("IQ_START", 0)
    nsamp  = _envi("IQ_NSAMP", 60000)
    seed   = _envi("IQ_SEED", 0)
    chan   = (os.environ.get("IQ_CHAN", "").strip() or "awgn")
    snr_s  = os.environ.get("IQ_SNRDB", "").strip()
    snr_db = float(snr_s) if snr_s else None
    gn_s   = os.environ.get("IQ_GAINS", "").strip() or "0,-2,-4,-6"
    gains_db = [float(g) for g in gn_s.split(",")]
    ph_s   = os.environ.get("IQ_PHASES", "").strip() or "0,35,70,110"
    phases = [np.radians(float(p)) for p in ph_s.split(",")]
    bw_sel = 1 if bw_khz == 125 else 0

    print(f"iq_stimulus: {path}")
    print(f"  sr_in={sr_in:.0f}  SF{sf}/BW{bw_khz}  [{start}:{start + nsamp}]  "
          f"chan={chan} snr={snr_db} gains_db={gains_db} phases_deg={ph_s} seed={seed}")

    x = ic.load_capture(path)
    x = x[start:start + nsamp] if nsamp > 0 else x[start:]
    if len(x) == 0:
        sys.exit("iq_stimulus: empty clip -- check IQ_START/IQ_NSAMP")

    x32 = ic.resample_to_chip_rate(x, sr_in)          # -> 32 MS/s complex64
    chans = ic.make_channels(4, model=chan, sample_rate=ic.CHIP_RATE_HZ,
                             phases=phases, gains_db=gains_db, seed=seed)
    branches = ic.fan_out_branches(x32, 4, snr_db, channels=chans, seed=seed)

    # ONE common sigma-delta scale across all branches -> per-antenna power
    # ordering survives into the 1-bit streams (see iq_capture.prepare_stimulus).
    gpeak = max(
        max(float(np.max(np.abs(xb.real))), float(np.max(np.abs(xb.imag))))
        for xb in branches)
    scale = 0.95 / max(gpeak, 1e-12)
    bpow = [float(np.mean(np.abs(xb) ** 2)) for xb in branches]

    n32 = len(x32)
    if n32 > IQ_MAX:
        sys.exit(f"iq_stimulus: {n32} chip samples > tb IQ_MAX {IQ_MAX} "
                 f"-- reduce IQ_NSAMP")

    bi = np.empty((4, n32), dtype=np.uint8)
    bq = np.empty((4, n32), dtype=np.uint8)
    for b, xb in enumerate(branches):
        bi[b], bq[b] = ic.sigma_delta_1bit(xb, scale)

    packed = ((bq[3] << 7) | (bq[2] << 6) | (bq[1] << 5) | (bq[0] << 4) |
              (bi[3] << 3) | (bi[2] << 2) | (bi[1] << 1) | bi[0]).astype(np.uint8)

    np.savetxt(OUT / "iq_stim.hex", packed, fmt="%02x")
    (OUT / "iq_stim.cfg.vh").write_text(
        "// generated by iq_stimulus.py -- do not edit\n"
        f"`define IQ_SF     {sf}\n"
        f"`define IQ_BWSEL  {bw_sel}\n"
        f"`define IQ_NSAMP  {n32}\n")

    print(f"  {n32} chip samples @32MS/s ({n32 / 32e6 * 1e3:.2f} ms sim)")
    print(f"  realised branch power = {[round(p, 5) for p in bpow]}")
    print(f"  wrote iq_stim.hex, iq_stim.cfg.vh (SF={sf} BWSEL={bw_sel})")


if __name__ == "__main__":
    main()
