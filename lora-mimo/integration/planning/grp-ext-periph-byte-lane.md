# GRP window byte-lane read fix

**Status:** FIXED 2026-08-28 (grouper local integration patch). Found the same
day by `integration/tb/tb_chip_top.v`.

## The bug

Grouper firmware doing `lbu` from Trouper GRP registers via the `0x8001_0000`
ext-periph window:

| CPU access | before fix | after fix |
|---|---|---|
| `lbu` at byte offset `0x_0/0x_4/0x_8/0x_C` (addr[1:0]==0) | correct | correct |
| `lbu` at any other byte offset (addr[1:0] != 0) | **0x00** | correct |
| `sb` at any byte offset | correct | correct |

So Trouper's byte-packed multi-byte readback fields (`Z_kl` 0x40–0x63, `Z_kk`
0x64–0x6F, `N_ACC` 0x21–0x23, `SC_STAT` 0x24–0x25, `sc_first_hit_dbg`
0x28–0x2B, ...) were only readable one byte in four.

## Mechanism

Not a bug in `ahb_to_grp_bridge` — the byte address reached `GRP_ADDR`
intact and reg_bank/peek returned the right byte (the SPI oracle read all of
them fine). The truncation was on the **Grouper side**:

- `periph_ss.sv`: `ext_periph_HRDATA = {24'b0, ext_HRDATA}` — the 8-bit
  slave's data was zero-extended into **HRDATA[7:0]** regardless of byte lane.
- `picorv32.v` (~L421): a byte load extracts
  `mem_rdata_word = {24'b0, mem_rdata[8*addr[1:0] +: 8]}` — the **addressed**
  lane. `cpu_ss.sv` passes HRDATA straight through (`mem_rdata = HRDATA`).

For `addr[1:0] != 0` those disagreed: data in lane 0, picorv32 read lane
1/2/3, got 0. Writes were unaffected because picorv32 replicates the store
byte to every lane (`mem_la_wdata = {4{rs2[7:0]}}`), so periph_ss's
`HWDATA[7:0]` tap always saw it.

## Fix

`periph_ss.sv`, one line, in `patches/grouper-local-integration.patch`:

```verilog
-  assign ext_periph_HRDATA = {{(DATA_WIDTH-EXT_DATA_WIDTH){1'b0}}, ext_HRDATA};
+  assign ext_periph_HRDATA = {(DATA_WIDTH/EXT_DATA_WIDTH){ext_HRDATA}};
```

Replicate the 8-bit read data across every byte lane instead of zero-extending
into lane 0 — the same trick picorv32 already uses on its store path, so the
two directions are now symmetric. picorv32's lane select then lands on the
byte for any address. Cost: zero gates (rewiring only, `{4{x}}` vs
`{24'b0,x}`).

Not a functional change for standalone Grouper: `ext_periph_HRDATA` only
carries data when the external-peripheral slot (SLOT_EXT_PERIPH) is actually
driven, which happens only in chip_top — Grouper's own UART/GPIO/SPI/QSPI
peripherals are on other slots and untouched. Should still ride along on the
next grouper chip-core synth/regression as due diligence.

Consequence retained: a 32-bit `lw` from this window returns `{4{byte}}`, not
a packed word. Multi-byte fields are read one `lbu` per byte and reconstructed
in firmware (which is what Trouper's byte-packed register map already assumes
— reg_bank.v: "big-endian multi-byte fields"):

```c
uint32_t z01_i_24 = (grp_rd8(0x40) << 16) | (grp_rd8(0x41) << 8) | grp_rd8(0x42);
```

## Regression

`tb_chip_top.v`:
- T3a — `lbu 0x08` (aligned) and `lbu 0x09` (unaligned) both read the register.
- T3b — CPU byte-copies Z_01_I (0x40..0x42) into W shadow (0x30..0x32);
  unaligned GRP reads and writes composed into one multi-byte field copy,
  checked over SPI.
