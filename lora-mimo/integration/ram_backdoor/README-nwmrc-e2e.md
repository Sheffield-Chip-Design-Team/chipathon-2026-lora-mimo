# Grouper–Trouper NW-MRC End-to-End Bench

This bench proves the deployed hybrid firmware path across the real Grouper
PicoRV32, AHB-to-GRP bridge, Trouper register bank, training accumulator, and
MRC combiner.

## Flow under test

1. Firmware releases `RX_HOLD` and arms `TACC_NOISE_TRIG`.
2. The foreground observes `NOISE_READY` and folds `ZDIAG/N_ACC` into the
   production per-branch Q16 noise EMA.
3. Firmware enables the native Grouper external interrupt for Trouper.
4. The following packet's `TRAINING_DONE` invokes the production
   `compute_eigvec_weights_fw()` kernel in the IRQ handler.
5. Firmware writes W shadow and pulses `W_COMMIT`; the test requires an active
   MRC combiner output that used those weights.

The noise path is polled because it is packet-free. `TRAINING_DONE` is native
IRQ-driven because W must be committed within the packet/replay timing budget.

## Firmware memory budget

The image is built for RV32EMC and linked into Grouper's 4 KiB RAM. The passing
image is **2,968 B**, below the 3 KiB code-image limit. It uses a 48-byte RV32E
IRQ register frame and the normal application stack; no dedicated 512-byte IRQ
stack, UART, `printf`, or diagnostic formatter is linked.

## Run

From `lora-mimo/integration`, in the chipathon container:

```bash
fusesoc --cores-root /foss/designs/integration run --target=sim \
  lora_mimo:integration:grouper_trouper_nwmrc_e2e
```

The core is [`ram_backdoor_nwmrc.core`](../ram_backdoor_nwmrc.core). Its
pre-build hook compiles the RAM-resident firmware test and the Grouper ROM
bootloader, then stages the cocotb module into the FuseSoC work directory.

## Evidence

The cocotb test reports success only after the RAM boot completes, the firmware
has committed valid W, and `u_comb` produces an output with `use_mrc_r=1`.
The latest local run passed at 13.585 ms simulation time.
