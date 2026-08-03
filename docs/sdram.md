# GW2AR-18 embedded SDRAM — facts, and the plan for a controller

Everything here is either from `docs/Gowin FPGA IC Docs.pdf` (GW2AR series data sheet,
DS226-2.7E) or measured by experiment against `gw_sh`. The experiments are recorded because the
answers are not written down anywhere obvious and were expensive to obtain.

## What the part actually is

The SDRAM is **system-in-package**: a die inside the GW2AR-18 package, not a board component. It
appears nowhere on the Tang Nano schematic — searching every sheet for `SDRAM`, `DRAM`, `W98`,
`IS42` or `MT48` returns nothing.

| Property | Value | Source |
|---|---|---|
| Type | SDR SDRAM, LVTTL, 3.3 V | data sheet §2.2.1 |
| Capacity | **64 Mbit = 8 MB** | data sheet |
| Data width | **32 bits** | data sheet |
| Organisation | **4 banks × 2048 rows × 256 columns × 32 bits** | data sheet §2.2.1 |
| Max clock | **166 MHz** | data sheet |
| Access time | 5.4 ns | data sheet |
| CAS latency | **2 or 3**, programmable | data sheet |
| Burst lengths | 1, 2, 4, 8, full page; sequential or interleaved | data sheet |
| Refresh | **4096 cycles / 64 ms → one AUTO REFRESH every 15.625 µs** | data sheet |
| Byte masking | yes, via DQM | data sheet |

4 × 2048 × 256 × 32 = 67,108,864 bits, which is exactly 64 Mbit. The same geometry appears
independently in Gowin's `SDRC_EMB` IP defines, so two sources agree.

## The pin mapping: the port names are magic

**Determined by experiment, because it is not documented and not derivable from any file in the
IDE.** No `.cst` template ships with the tools, the device data files contain no SDRAM strings,
and the I/O table describes only I/O standards.

A minimal design was built twice, identical except for the names of its 55 SDRAM ports:

| Port names | Result |
|---|---|
| `O_sdram_clk`, `O_sdram_cke`, `O_sdram_cs_n`, `O_sdram_ras_n`, `O_sdram_cas_n`, `O_sdram_wen_n`, `O_sdram_dqm[3:0]`, `O_sdram_addr[10:0]`, `O_sdram_ba[1:0]`, `IO_sdram_dq[31:0]` | **Places and routes with no constraints at all.** All 55 land on `p`-prefixed die pads (`p1`, `p2`, `p5`, `p73`, `p89`, …) that are not bonded to package pins. Report shows `I/O Port 2/66` — only `clk` and `led` count. |
| the same ports renamed `X_foo_*` | **`ERROR (PA2024): The number(57) of ports exceeds the resource limit 53 regular I/Os`** — the tool treats them as ordinary I/O and they do not fit. |

Three conclusions, all load-bearing:

1. **Use exactly those port names on the top-level module** and Gowin bonds them to the SIP die
   automatically. Get a name wrong and the design either fails to fit or silently drives a
   package pin instead.
2. **No pin constraints are needed or wanted** for the SDRAM. Do not add any to the `.cst`.
3. **The SDRAM costs zero package pins.** It does not compete with the twelve probe channels or
   with the twenty pins the RGB LCD connector reserves for Phase 3/4.

That error message also confirms the device's pin budget exactly, and explains why `la_capture`
had to reclaim the SSPI pins: **53 regular + 1 RECONFIG_N + 4 JTAG + 4 SSPI + 4 MSPI = 66**.

## Why not use Gowin's IP

`SDRC_EMB` ("SDRAM Controller (With Embedded SDRAM)") exists, supports `GW2AR-18C-QFN88`, and is
readable Verilog rather than an encrypted blob. It was still rejected:

- Its `top_defines.v` **is** encrypted (`pragma protect`), and the source files depend on macros
  from it. The sources cannot be compiled by iverilog as shipped; they are templates meant to be
  filled in by the GUI IP generator. That breaks `make sim`, which this repo treats as
  non-negotiable — see `docs/verification.md`.
- Gowin's own documentation calls it legacy: *"It should be considered for legacy designs. New
  designs should consider using SDRAM Controller HS."*
- **Gowin ships no simulation model for the SDRAM itself.** From the IP's `Readme.txt`:
  *"Currently, we do not provide simulation models. If you need to use it, please contact Micron
  Technology … (MT48LC8M16A2)."* So adopting the IP would still leave us writing the model that
  makes any of it testable.

Since the hard part — the pin mapping — turns out to be free, and the model has to be written
either way, a controller we can read, simulate and shape to this project's access patterns is
the better trade.

## Design decisions for our controller

**Run it at 108 MHz, in the existing clock domain.** Well inside the 166 MHz maximum, and it means
capture, control, UART and SDRAM all share one clock — the probe pins stay the design's only
clock-domain crossing. Peak bandwidth is 108 MHz × 32 bits = **432 MB/s** against the 8.69 MB/s
the Prime's bus produces, so there is roughly 50× headroom for refresh and row-change overhead.

**Timing parameters are conservative, not part-specific.** The data sheet gives 166 MHz and a
5.4 ns access time but no AC table; it defers to IPUG279, which is not installed. Standard SDR
values are used, rounded up in cycles at 108 MHz (9.26 ns):

| Parameter | Value used | Cycles @108 MHz |
|---|---|---|
| power-up wait | 200 µs | 21,600 |
| tRP (precharge → activate) | 20 ns | 3 |
| tRCD (activate → read/write) | 20 ns | 3 |
| tRAS (activate → precharge) | 45 ns | 5 |
| tRC (activate → activate, same bank) | 70 ns | 8 |
| tRFC (refresh cycle) | 70 ns | 8 |
| tWR (write recovery) | 15 ns | 2 |
| tMRD (mode register set) | 2 cycles | 2 |
| CAS latency | 3 | 3 |
| refresh interval | 15.625 µs | 1687 |

With 50× bandwidth headroom, buying certainty with conservative timing costs nothing that
matters. If throughput ever becomes tight these are the first numbers to revisit — against a real
AC table, not against guesses.

**The SDRAM clock needs a phase offset.** `O_sdram_clk` drives the die, and the DQ bus has to meet
setup and hold against it. Gowin's IP takes two clocks (`I_sdrc_clk` and `I_sdram_clk`) for
exactly this reason. Our `rPLL` can produce a phase-shifted second output (`CLKOUTP`, `PSDA_SEL`).
The offset is a tuning parameter to be determined on hardware; it is the most likely cause of a
controller that simulates perfectly and reads garbage from the real die.

## Why this is being built now

Two independent requirements converge on it, neither satisfiable with block RAM:

| Requirement | Needs | BSRAM has |
|---|---|---|
| Phase 2 — capture a whole frame | 2,864,767 samples (26.53 ms at 108 MHz) | 32,768 samples |
| Phase 4 — frame buffer for retiming | 320×240 RGB565 = 1.23 Mbit | 828 Kbit, half already used |

See `docs/prime_lcd_protocol.md` for where the frame figure comes from, and
`docs/panel_afy320240a0.md` for why Phase 4 must retime rather than pass through.

## Build order

1. **Behavioural SDRAM model** (`sim/models/sdram_sim.v`) — the oracle. Must *check* the
   protocol, not merely respond to it: initialisation sequence, per-bank state, tRP/tRCD/tRAS/tRC,
   CAS latency, refresh interval. Gowin supplies nothing here, and without it nothing downstream
   is testable.
2. **Controller** (`src/common/sdram_ctrl.v`) — init, auto-refresh, single-word read/write.
3. **Testbench** against the model, mutation-tested as usual.
4. **Streaming interface** — sequential burst write and burst read, which is what capture and
   frame-buffer traffic actually look like.
5. **Hardware target**, and only then the clock-phase tuning.
