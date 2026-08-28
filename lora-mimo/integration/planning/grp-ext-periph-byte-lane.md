# GRP window: Grouper can write any byte, but only reads word-aligned bytes

**Status:** open interface issue, found 2026-08-28 by `integration/tb/tb_chip_top.v` (T3).
**Severity:** medium — constrains firmware; may need an RTL fix depending on the
firmware's Z/Z_kk/N_ACC access pattern.

## Symptom

Grouper firmware doing `lbu` from Trouper GRP registers via the
`0x8001_0000` ext-periph window:

| CPU access | result |
|---|---|
| `lbu` at byte offset `0x_0`, `0x_4`, `0x_8`, `0x_C` (addr[1:0]==0) | correct |
| `lbu` at any other byte offset (addr[1:0] != 0) | **returns 0x00** |
| `sb` at **any** byte offset | correct |

So a `reg_bank` register at e.g. 0x08 reads fine; 0x09/0x0A/0x0B read as 0.
Trouper's byte-packed multi-byte readback fields are the ones that hurt:
`Z_kl` 0x40–0x63, `Z_kk` 0x64–0x6F, `N_ACC` 0x21–0x23, `SC_STAT` 0x24–0x25,
`sc_first_hit_dbg` 0x28–0x2B, etc. Only every 4th byte is reachable.

## Mechanism

Not a bug in `ahb_to_grp_bridge` — the byte address reaches `GRP_ADDR`
intact, and reg_bank/peek returns the right byte (confirmed: the SPI oracle
reads all of them correctly, and `GRP_RDATA` carries the right value).

The truncation is on the **Grouper side**, structural to its 8-bit
`EXT_DATA_WIDTH` external-peripheral port:

- `periph_ss.sv` (~L597): `ext_periph_HRDATA = {24'b0, ext_HRDATA};`
  the 8-bit slave's data is zero-extended into **HRDATA[7:0]** regardless of
  the transfer's byte lane.
- `picorv32.v` (~L421): a byte load extracts
  `mem_rdata_word = {24'b0, mem_rdata[8*addr[1:0] +: 8]}` — it takes the byte
  from the **addressed lane** of HRDATA.

For `addr[1:0] != 0` those disagree: the data is in lane 0, picorv32 reads
lane 1/2/3, gets 0. `cpu_ss.sv` passes `HRDATA` straight through
(`mem_rdata = HRDATA`), no lane replication.

Writes are unaffected because picorv32 replicates the store byte to every
lane (`mem_la_wdata = {4{rs2[7:0]}}`), so `periph_ss`'s `HWDATA[7:0]` tap
always sees it.

A software `lw` from an aligned base does **not** recover the packed bytes
either: `ext_HRDATA` only ever populates HRDATA[7:0], so `lw 0x40` yields
`0x000000` ++ `reg_bank[0x40]`, not the four packed bytes.

## Options

1. **Firmware works around it** — only viable if every GRP field Grouper
   needs to *read* is placed at a word-aligned offset in Trouper's map, or
   Grouper reads them one aligned `lbu` per byte with the register map
   rearranged. Trouper's current map is dense byte packing, so this means a
   Register Map change on the Trouper side (coordinate with that team).
2. **Bridge replicates read data across lanes** — `ahb_to_grp_bridge` drives
   `HRDATA = {4{response_rdata}}` instead of `{24'b0, response_rdata}`, and
   `periph_ss` forwards the full 32 bits (it currently forces the top 24 to
   0). Then picorv32's lane extract lands on the right byte for any offset.
   Cleanest, but touches grouper's `periph_ss` (already carrying a local
   integration patch) — fold it into that patch.
3. **Widen the ext bus** — `EXT_DATA_WIDTH = 32` end to end and let the
   bridge present a real 32-bit-that-is-really-8 slave. Largest change.

Option 2 is the recommended fix; until then, treat "Grouper reads GRP
registers at word-aligned offsets only" as a hard constraint and keep
`tb_chip_top.v` T3 as the regression that pins it.
