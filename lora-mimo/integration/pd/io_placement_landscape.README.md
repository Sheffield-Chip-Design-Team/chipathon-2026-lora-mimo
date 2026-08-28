# io_placement_landscape.cfg — rationale

First real combined pinout for `chip_top` on the Grouper<->Trouper landscape
die (2235 x 2235). Rewritten 2026-08-28 from the earlier Trouper-only guard.

**Format note:** the LibreLane `Odb.CustomIOPlacement` parser treats every `#`
line as a direction marker (`#N`/`#S`/`#E`/`#W`) — it does **not** accept `#`
comments. Keep the `.cfg` free of them (job 5128 failed here: "identifier/regex
'#' requires a direction to be set first"). This README carries the notes.

## Geometry / side budget

- Grouper = NW L-shape -> pins on `#W` (y 1117.5..2235) + `#N` (x 0..1665)
- Trouper = SE square    -> pins on `#S` (x 1117.5..2235) + `#E` (y 0..1117.5)
- The other half of each edge backs an obstruction (dead) and is padded with
  virtual pins (`$N`) so the real pins land in the usable half.
- Pitch: 2235 / 22 = 101.6 um. Every side totals 22 slots. Usable: NW 27
  (11 on `#W` + 16 on `#N`), SE 22 (11 on `#S` + 11 on `#E`).

## Assignment

| Side | Real pins | Virtuals |
|------|-----------|----------|
| `#S` | `IQ_CLK`, `IQ_DATA_I/Q[0:3]`, `REMOD_A_I/Q` (11) | `$11` leading (dead left half) |
| `#N` | `GPIO_5..15` (11), then `HOST_CS`, `SPI_SCK`, `SPI_MOSI`, `SPI_MISO` at the east end | `$1` spare between them; `$6` trailing (x 1665..2235, Obstruction B) |
| `#W` | `HCLK`, `HRESETn`, `UART_RX`, `UART_TX`, `GPIO_0..4` (9) | `$11` leading (dead lower half); `$2` trailing = Grouper VSS/VDD reserve |
| `#E` | `PSRAM_SCK`, `PSRAM_CE_N`, `PSRAM_SIO_0..3`, `IRQ_OUT` (7) | `$4` = 2 signal spare + Trouper VSS/VDD reserve; `$11` trailing (dead upper half) |

## Rationale

- Trouper datapath stays on its own SE edges (`#S` radio-facing, `#E` PSRAM).
- The `<=10 MHz` host SPI slave is exiled to `#N`'s east end (nearest Trouper's
  SE logic, shortest cross-neck route) so the otherwise-full SE side has room
  for Trouper's own power reserve. 100 ns period vs. a ~2 mm route = fine.
- Shared `HCLK`/`HRESETn` sit low on `#W`, near the y=1117.5 seam — the most
  central point of that edge, shortest reach to both blocks.
- One VSS/VDD pair per project, held as `$` reserve for now: chip_top is
  core-only (no RTL power ports), so real `VSS`/`VDD` names can't go in the
  `.cfg` yet. When the padframe adds them: Grouper pair at the `#W` `$2`
  (low, near the seam); Trouper pair at the `#E` `$4` (low, matches the
  modelled "Trouper east" downbond at (2180, 388)).
- Spare signal slots: 1 on `#N` (between `GPIO_15` and the SPI group), 2 on
  `#E`. Held as reserve (late-ECO / bond options). REMOD_B was considered and
  rejected 2026-08-27.

## Dependencies

- `chip_top.v` must expose `UART_TX`/`UART_RX`/`GPIO_0..15` (done 2026-08-28 —
  GPIO as always-driven `inout`, no top-level tri-state; see that file).
- The Grouper SRAM row stays at job 5069's `y=1695.67` (flush with the north
  edge). The ~15 `#N` Grouper nets route OVER the macros on Metal4/Metal5
  (macro OBS blocks M1-M3 only). If a run shows congestion/antenna there, move
  the row down — see `config_landscape_2235.yaml` MACROS.
