# Verification: why the testbench is the primary instrument

**Read this before writing RTL for a new phase.** It is not general advice — every claim below is
grounded in something that actually happened in this repo, with the cost it actually incurred.

## The thesis

In software you can print a variable, re-run, and know something in seconds. On an FPGA you
cannot. Between your source and the observable world sit synthesis, place-and-route, bitstream
generation, a configuration cycle, pin multiplexing, board strapping, level shifting, a host
driver stack, and a serial protocol. **Every one of those layers can fail silently, and most of
them fail in ways that look identical from the outside: nothing happens.**

That is the whole problem. "Nothing happens" is the least informative failure mode in existence,
and it is the *default* failure mode of hardware. A testbench is how you convert "nothing happens"
into a specific claim about a specific signal at a specific time.

So: **the testbench is not a quality gate you add after the design works. It is the instrument you
use to make the design work.** Skipping it does not defer the cost; it converts a cheap,
observable, fully-controllable cost into an expensive, unobservable, partially-controllable one.

## What it cost here, concretely

proto-phase-1 is a trivial design: two UARTs, an LFSR, a mux, six LEDs. It had a testbench —
`sim/targets/bringup_uart_loopback/` — which passed cleanly the entire time. It tested `uart_tx`
against `uart_rx`.

Nothing tested the top level. The result:

| Bug | Where a testbench would have caught it | Actual cost |
|---|---|---|
| `rst` on pin 88 (`MODE0` config strap) held the whole design in reset | A top-level tb driving `rst` and asserting "TX produces bytes" would have forced the question of what `rst` actually does on this board | **Three debugging sessions.** Built an entire Arduino Uno bridge — resistor divider, two sketch rewrites, `arduino-cli` toolchain, a second self-test script, ~500 lines of docs — to route around a bug that was never in that part of the system |
| LFSR advanced **twice** per transmitted byte (`tx_ready` is high for 2 cycles/byte) | Immediately: count `en` pulses vs byte launches | Would have made the hardware self-test fail *forever* with a data mismatch, even over a perfect link |
| Free-running TX gave a receiver no way to establish framing | Immediately: decode the stream and assert byte 0 == SEED | Same — permanently unpassable, with a symptom (garbage bytes) that invites blaming the wiring |
| `tx_ready` used before declaration → implicit net | Instantly: `iverilog` refuses to elaborate it | Gowin only emitted `WARN (EX3638)`, which was read as cosmetic for three sessions |

The last row is the sharpest lesson. **The bug that stopped the testbench from existing was itself
one of the bugs.** `bringup_selftest_top.v` could not be elaborated by Icarus at all. Nobody found
that out, because nobody tried to simulate it. A vendor toolchain that "succeeds with warnings"
will happily let you ship a netlist built from a file that is not legal Verilog.

Writing the missing testbench took about twenty minutes. It found three real bugs immediately.

## Rules

1. **Every synthesizable target gets a top-level testbench.** Not just its submodules. Module-level
   tests verify the parts you thought about; integration tests verify the assumptions *between*
   them, which is where the bugs are. `bringup_uart_loopback` passed while the top level was
   comprehensively broken.

2. **Simulate before you synthesize, always.** `make sim` is seconds; `make build` is minutes;
   a hardware debug session is hours. The ordering is not a preference, it is an economic fact.
   If a design has never been simulated, "it built" tells you nothing about whether it works.

3. **Treat every toolchain warning as an error until you have read and understood it.** Grep the
   build log for `WARN` after every build. `WARN (EX3638)` was a genuine language-level defect
   reported in plain text in every single build log for three sessions.

4. **Measure, do not assume.** The testbench recovers the actual baud rate from the wire (the
   narrowest edge-to-edge interval in UART framing is exactly one bit time) rather than trusting
   that `CLK_HZ / BAUD` came out right. Integer division truncation, wrong clock constants and
   parameter-override mistakes all produce a plausible-looking design that transmits at the wrong
   speed. Assert on the measurement.

5. **Every register gets a reset term, especially liveness indicators.** The heartbeat counter was
   declared `always @(posedge clk)` with no reset, so `leds[0]` blinked merrily while every other
   register in the design was held in reset. Every "the bitstream is alive" check was true and
   worthless simultaneously. **An indicator that cannot distinguish *configured* from *running* is
   worse than no indicator**, because it actively redirects your attention elsewhere.

6. **Prefer diagnostics that cannot be misread.** `leds[3]` (sticky "≥1 valid byte received since
   reset") is a good diagnostic: it only ever goes off→on, needs no timing, and needs no knowledge
   of what state to expect. `leds[1]` (current mode) is a poor one: it is a snapshot that requires
   you to already know the answer to interpret it.

7. **Check the pin report's Function column before mapping any signal.** `impl/pnr/project.rpt.txt`
   listed pin 88's function as `MODE0` from the very first build. Dual-purpose pins (`MODE*`,
   `DONE`, `RECONFIG_N`, `READY`, `JTAGSEL_N`) are strapped on the PCB and will ignore your
   `PULL_MODE`.

8. **Change one variable at a time, and keep a known-good state to fall back to.** When the link
   finally came up, moving from the Arduino bridge to the BL616 was done as: change pins only
   (keep baud) → verify → change baud → verify. Each step had exactly one suspect.

## Writing testbenches that work

Hard-won specifics from `sim/targets/bringup_selftest/tb_bringup_selftest.v`:

- **The PASS/FAIL contract is non-negotiable** (see `CLAUDE.md`): exactly one `PASS:` + `$finish`
  or `FAIL:` + `$fatal(1)`, plus a watchdog. `tools/sim/run_sim.sh` greps for it. An agent — or a
  CI job, or you at 1am — must be able to parse the result without judgement.

- **Count the watchdog in clocks, not `#delay`.** Verilog's default unsized integer literal is
  32 bits. A 22 ms timeout expressed in ps overflows it silently and your watchdog fires
  immediately or never.

- **Arm the receiver before the stimulus finishes.** `uart_rx` asserts `rx_valid` at the *middle*
  of the stop bit, and the DUT's response begins ~4 clocks later — while `send_byte` is still
  driving the rest of that stop bit. A sequential `send(); receive();` misses the first start bit
  and misframes every byte. Use `fork`/`join`. Real hosts don't have this problem (their UART is
  always listening and the OS buffers), which makes it a pure testbench artifact — and a
  convincing one, since it looks exactly like a real framing bug.

- **Use hierarchical references to assert on internals.** `dut.u_lfsr.en` vs
  `dut.tx_ready && dut.tx_valid` proved the 2:1 LFSR cadence bug directly and unambiguously. You
  do not have to infer internal behaviour from output bytes when you can just look.

- **Make the failure message carry the evidence.** `FAIL: byte 0 mismatch: expected=0x01 got=0x40
  (first 8 captured: 40 20 10 28 ...)` is diagnosable from the log alone. Printing the captured
  prefix is what revealed the misframing — the sequence visibly converged onto the expected one.

## When a hardware test fails, suspect your instrument too

The Arduino line probe used in this session reported ~590 kbaud for a 115200 link, because
`micros()` depends on Timer0's overflow ISR and the sampling loop ran with interrupts disabled.
The measurement was confidently wrong.

Simulation is the authority on what the RTL does, because it is the only place where you control
every variable. Use hardware to test the things simulation cannot model — pin mapping, board
strapping, drivers, host software — and go back to simulation the moment the question is
"what does my design do?"
