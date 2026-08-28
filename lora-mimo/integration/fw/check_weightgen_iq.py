#!/usr/bin/env python3
"""
check_weightgen_iq.py -- bit-exact post-check for tb_chip_top.v STIM=iq (T5).

The tb drove a real IQ capture through Trouper's DSP chain, let the real
Grouper weight-gen firmware read the resulting Z over the AHB->GRP bridge and
write MRC weights, then SPI-oracle-dumped the measured Z + N_ACC + the
firmware's W shadow into iq_result.txt.

This rebuilds the 4x4 Hermitian Z (register units) from those measured bytes,
runs Trouper's own reference model
    sim/models/eigvec_fw.compute_eigvec_fw(Z, n_acc, register_units=True)
(sigma2_zdiag=None -- the firmware takes NO noise whitening in its cold state:
crt0 zeroes the noise EMA and the tb never arms TACC_NOISE_TRIG), and asserts
the firmware's W bytes match. The firmware kernel is verified bit-exact against
that model (see fw/weightgen_stimulus.py / T4), so this must match exactly --
the only new variable in T5 is that Z is *measured*, not forced.

Usage:  DESIGN_ROOT=<trouper> python3 check_weightgen_iq.py [iq_result.txt]
Exit 0 = match, 1 = mismatch / parse error.
"""
import os
import sys
import pathlib

import numpy as np

_root = os.environ.get("DESIGN_ROOT") or os.environ.get("TROUPER_ROOT") or "/trouper"
if _root not in sys.path:
    sys.path.insert(0, _root)
from sim.models.eigvec_fw import compute_eigvec_fw  # noqa: E402

PATH = sys.argv[1] if len(sys.argv) > 1 else "iq_result.txt"

# pair index -> (k, l), matching reg_bank 0x40.. order
PAIRS = [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]


def s24(b0, b1, b2):
    v = (b0 << 16) | (b1 << 8) | b2
    return v - (1 << 24) if v & 0x800000 else v


def u24(b0, b1, b2):
    return (b0 << 16) | (b1 << 8) | b2


def s16(v):
    v = int(round(v)) & 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def main():
    txt = pathlib.Path(PATH).read_text().splitlines()
    nacc_b, zb, wb = None, None, None
    for ln in txt:
        ln = ln.strip()
        if ln.startswith("NACC"):
            nacc_b = [int(x, 16) for x in ln.split()[1:]]
        elif ln.startswith("Z"):
            zb = [int(x, 16) for x in ln.split()[1:]]
        elif ln.startswith("W"):
            wb = [int(x, 16) for x in ln.split()[1:]]
    if not (nacc_b and zb and wb):
        sys.exit(f"check_weightgen_iq: could not parse {PATH}")
    if len(zb) != 48 or len(wb) != 16 or len(nacc_b) != 3:
        sys.exit(f"check_weightgen_iq: bad field lengths "
                 f"Z={len(zb)} W={len(wb)} NACC={len(nacc_b)}")

    n_acc = ((nacc_b[0] & 0x03) << 16) | (nacc_b[1] << 8) | nacc_b[2]

    # Z region is 0x40..0x6F: 6 pairs x 6 bytes (I hi/mid/lo, Q hi/mid/lo),
    # then 4 diagonals x 3 bytes.
    Zm = np.zeros((4, 4), dtype=complex)
    for p, (k, l) in enumerate(PAIRS):
        o = 6 * p
        re = s24(zb[o + 0], zb[o + 1], zb[o + 2])
        im = s24(zb[o + 3], zb[o + 4], zb[o + 5])
        Zm[k, l] = re + 1j * im
        Zm[l, k] = re - 1j * im
    for k in range(4):
        o = 36 + 3 * k
        Zm[k, k] = u24(zb[o + 0], zb[o + 1], zb[o + 2])

    zdiag = [int(Zm[k, k].real) for k in range(4)]
    print(f"measured n_acc = {n_acc}")
    print(f"measured ZDIAG = {zdiag}")
    print("measured Z_kl  = " +
          ", ".join(f"{PAIRS[p]}:{int(Zm[PAIRS[p]].real)}{int(Zm[PAIRS[p]].imag):+d}j"
                    for p in range(6)))

    if n_acc == 0 or all(z == 0 for z in zdiag):
        sys.exit("check_weightgen_iq: degenerate Z (n_acc=0 or ZDIAG all-zero) "
                 "-- training did not accumulate signal")

    offd = [Zm[PAIRS[p]] for p in range(6)]
    if len(set(zdiag)) == 1 and len({(round(z.real), round(z.imag)) for z in offd}) == 1:
        sys.exit("check_weightgen_iq: degenerate Z -- every ZDIAG and every Z_kl "
                 "identical (branches saw the same signal). Set distinct "
                 "IQ_GAINS / IQ_PHASES so the eigenvector test is non-trivial.")

    w = compute_eigvec_fw(Zm, n_acc=n_acc, register_units=True)
    exp = []
    for k in range(4):
        exp += [(s16(w[k].real * 32768.0) >> 8) & 0xFF, s16(w[k].real * 32768.0) & 0xFF,
                (s16(w[k].imag * 32768.0) >> 8) & 0xFF, s16(w[k].imag * 32768.0) & 0xFF]

    ok = exp == wb
    print("\n idx  reg   fw    golden")
    labels = [f"W{k}_{c}" for k in range(4) for c in ("re_hi", "re_lo", "im_hi", "im_lo")]
    for i in range(16):
        mark = "" if wb[i] == exp[i] else "  <-- MISMATCH"
        print(f" 0x{0x30 + i:02x} {labels[i]:8s} 0x{wb[i]:02x}  0x{exp[i]:02x}{mark}")

    if ok:
        print("\nT5 PASS -- firmware W == eigvec_fw(measured Z)")
        return 0
    print("\nT5 FAIL -- firmware weights differ from eigvec_fw(measured Z)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
