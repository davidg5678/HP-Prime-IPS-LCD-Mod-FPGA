# FPGA projects with Claude Code — a playbook

A transferable setup for building FPGA projects with an AI agent doing most of the typing. Every
convention here was paid for: it exists because its absence cost a debugging session, a wrong
diagnosis, or a piece of hardware that sat dark for three days. Nothing in it is specific to the
project it grew in (an HP Prime calculator LCD reverse-engineering build on a Sipeed Tang Nano 20K),
though that project supplies the examples.

Copy this into a new repo, adapt the board and toolchain sections, and you skip the expensive part.

---

## 1. The central problem, and why it dictates everything else

In software you print a variable, re-run, and know something in seconds. On an FPGA you cannot.
Between your source and the observable world sit synthesis, place-and-route, bitstream generation,
a configuration cycle, pin multiplexing, board strapping, level shifting, a host driver stack, and
a serial protocol.

**Every one of those layers can fail silently, and most of them fail identically from the outside:
nothing happens.**

"Nothing happens" is the least informative failure mode in existence, and it is the *default*
failure mode of hardware. Worse, an agent cannot see an LED, hear a click, or notice that a board is
warm. It has exactly the observability you build for it, and nothing more.

Everything below is downstream of that one fact. The recurring theme is: **convert "nothing happens"
into a specific claim about a specific signal at a specific time, as early and as cheaply as
possible.**

### The economics that set the workflow

Measured on a mid-size design (capture path + SDRAM controller + display driver + UART):

| Step | Cost | What it can tell you |
|---|---|---|
| Verilator simulation | **~15 s** | does the RTL do what I meant, fully observable |
| Icarus simulation | ~4 min | same, second opinion, different strictness |
| Vendor synthesis + PnR | **~10 s** | does it fit, does it meet timing, are the pins legal |
| Flash to SRAM | ~5 s | — |
| Hardware test | seconds to **hours** | only the things simulation cannot model |

Note the surprise: **the build is not the slow step.** Simulation is, by an order of magnitude, and
hardware debugging is by three. Optimise in that order. The rule that falls out:

> Simulate before you synthesise. Synthesise before you flash. Use hardware only for the questions
> simulation structurally cannot answer — pin mapping, board strapping, analog behaviour, host
> drivers, and whether the thing is physically plugged in.

---

## 2. Repository layout

The key idea is **one directory per synthesizable target, with a manifest**, so build and simulation
scripts are fully generic and adding a new phase never means editing tooling.

```
src/common/                     reusable RTL, shared across targets
src/targets/<name>/
    <name>_top.v                the top level
    <name>.cst                  pin constraints (vendor format)
    <name>.sdc                  timing constraints  <- MANDATORY, see §6
    files.txt                   ordered source list, common modules first
    top_module.txt              the top module name
    options.tcl                 optional extra vendor build options
sim/targets/<name>/
    tb_<name>.v                 one top-level testbench
    files.txt, top_module.txt   same manifest convention
sim/models/                     third-party device models (SDRAM, PLL, ...)
tools/{setup,sim,build}/        all automation, generic over target name
python/tools/                   host-side control + telemetry
docs/                           protocol specs, datasheet analyses, this file
boards/<board>/pinout.md        the board's pin reference and traps
```

Adding a phase = adding two directories. The scripts never change. This matters more with an agent
than without one: a generic script is a thing the agent can *use correctly by default*, whereas a
per-target script is a thing it must first read, then modify, then get subtly wrong.

### The two documents that carry the project

- **`CLAUDE.md`** — instructions and hard-won constraints, loaded into the agent's context every
  session. Commands table, toolchain paths and their traps, conventions, and a **Known gotchas**
  section. This is not documentation; it is a standing brief. Keep it dense and current.
- **`PROGRESS.md`** — a session log, newest first, updated at the end of every working session so a
  cold start (human or agent) can pick up. **Record what failed and why, not just what worked.**
  Most of this playbook was extracted from that file.

Rule for both: **state clearly what has actually been run.** "Passes simulation, never synthesised,
never run on hardware" is a sentence that saves hours. An agent reading "Phase 3 is done" will
assume the panel works; reading "Phase 3 builds clean, no panel has ever been attached" it will
not.

---

## 3. The PASS/FAIL contract

Every testbench and every host-side hardware script prints **exactly one** of:

```
PASS: <summary with the numbers that matter>
FAIL: <reason, carrying the evidence>
```

plus `$finish` / `$fatal(1)` respectively, plus a watchdog. Runner scripts grep for it and set exit
codes accordingly.

This sounds trivial and is the single highest-leverage convention in the set. An agent, a CI job, or
you at 1am must be able to parse the result **without judgement**. A testbench that prints 200 lines
and expects a human to notice one wrong number is not a test.

Specifics that took a while to learn:

- **Count the watchdog in clocks, not `#delay`.** Verilog's default unsized literal is 32 bits; a
  22 ms timeout in picoseconds overflows silently and fires immediately or never.
- **Make the failure message carry the evidence.** `FAIL: byte 0 mismatch: expected=0x01 got=0x40
  (first 8: 40 20 10 28 ...)` is diagnosable from the log alone. Printing the captured prefix is
  what revealed a misframing bug — the sequence visibly converged on the expected one.
- **Put the real numbers in the PASS line too.** `PASS: emitting 320x240 in 371x260 at 62.2 Hz` is
  a regression detector. `PASS: ok` is not.
- **The PASS line must describe what actually ran, not what it resembles.** A summary once claimed
  "at 37.7 Hz-class timing" when only the *line* timing was real and the frame rate was 8× off. It
  named the one regime the test never entered — see §8.

---

## 4. Simulation: two engines, deliberately

Use **Verilator (`--binary --timing`) for the inner loop** and **Icarus for signoff**. Keep both.

```bash
make simq SIM_TARGET=<name>    # Verilator, one target   ~15 s
make simq-all                  # Verilator, ALL targets  ~57 s   <- the gate
make sim  SIM_TARGET=<name>    # Icarus, one target      ~4 min  <- on demand
```

**Full regression is the point, not single-target speed.** Under the slow simulator a sweep of all
targets ran ~30 minutes — long enough that nobody runs it, so in practice the suite was only ever
exercised one target at a time, and only the target somebody was already thinking about. At 19× it
becomes a thing you type before every commit. That matters because a shared `common/` directory
means a change to one phase reaches the others, which a single-target run cannot see.

Verilator 5 runs ordinary Verilog testbenches — `#delay`, `fork`/`join`, `wait()`, hierarchical
`dut.internal_signal` references, tristate `inout` buses, `$fatal` — compiled to C++ instead of
interpreted. On one testbench: **4 m 29 s → 14 s, a 19× speedup, identical verdict, zero source
changes.** Only `-Wno-fatal` was needed to get past pre-existing lint warnings.

Why keep two:

> **Every toolchain is permissive where another is strict, in both directions.** A signal used before
> declaration (an implicit net) is a *warning* in one vendor synthesiser and a *hard error* in
> Icarus. A reg driven from two `always` blocks is a *hard error* in that same synthesiser and
> simulates happily in Icarus. Agreement between independent implementations is evidence; a single
> tool passing is not.

Do not decide in advance which one is "the authority." The fast simulator was introduced here as a
convenience with the slow one kept as reference — and then the fast one immediately found a bug the
reference had hidden for the life of the project:

```verilog
localparam integer BIT_PS = 1_000_000_000_000 / BAUD;   // 1e12 > 2^32
```

An unsized Verilog integer literal is 32 bits, so this overflows during constant folding. One
simulator folds at wider precision and gets the right answer; the other follows the standard and
produces a garbage bit time that hangs a bit-banged UART. **The standard-conforming one was right.**
Note also that the project's own verification doc warned about this exact hazard — in a paragraph
about watchdog timeouts, while the bug sat two lines above the watchdog. **A documented trap is not
a defended one**; only an executable check is.

That is the same argument for keeping an open-source build path (yosys/nextpnr) alongside the
vendor one as a second opinion.

**Simulation cost scales with simulated time, not with how much you check.** One 16 ms display frame
is ~1.7 M clock cycles whether or not anything inspects it. So "check fewer pixels" saves nothing;
"wait fewer frames" saves everything. Budget accordingly.

### Rules for testbenches that actually work

1. **Every synthesizable target gets a top-level testbench, not just its submodules.** Module tests
   verify the parts you thought about; integration tests verify the assumptions *between* them,
   which is where the bugs are. A project once had a passing `uart_tx`↔`uart_rx` loopback test the
   entire time its top level had three bugs making it permanently unable to work — including one
   that meant the top level *could not be elaborated by the simulator at all*. Nobody found out,
   because nobody tried to simulate it.

2. **Mutation-test the testbench before trusting it.** Break the RTL on purpose; confirm the test
   fails, and that the message names the actual fault. This found dead logic in a trigger condition
   that could be deleted with every test still passing. Record the mutation table — it is the only
   evidence a test discriminates:

   | Mutation | Caught as |
   |---|---|
   | clock edge moved onto the data transition | `worst hold = 0.000 ns` |
   | porch shortened by one | `Th = 370, expected 371` |
   | refresh disabled | `refresh interval exceeded` |

3. **Measure, don't assume.** Assert on values *recovered from the design* — the actual bit time on
   the wire, the actual DCLK period — not on the constants you believe you set. Integer truncation,
   wrong clock constants and parameter-override mistakes all produce plausible-looking designs that
   run at the wrong speed.

4. **Use an independent implementation as the oracle.** If a capture path is tested with stimulus
   from a *different* module written for a different purpose, agreement is evidence. If the
   testbench's expected values are copied from the DUT's source, agreement is tautology. Write
   oracles from the *documented spec*, not from the code.

5. **Assert invariants continuously, not once.** If a design's correctness rests on "these two flags
   are never both set", check it on every clock edge rather than reasoning about it in a comment.

6. **Fork the receiver before sending the stimulus.** A DUT replies within a few clocks, while the
   testbench is still driving the last stop bit. Sequential `send(); receive();` misses the first
   start bit and misframes everything — a pure testbench artifact that looks exactly like a real
   framing bug. Real hosts don't have this problem because their UART is always listening.

7. **Never compare a DUT-internal signal against a pin-observed event.** Internal state changes
   several cycles before the corresponding edge appears at the pins. Sampling one against the other
   produces failures that are off by exactly one frame. Instead, accumulate the internal signal
   *over the window the pins define* — it removes the skew instead of compensating for it. This
   mistake was made, documented in a comment, and then made again in the same file.

8. **Shrink the right dimension, and say which.** Testbenches must run in seconds, so something has
   to give. Reducing the *active height* of a video frame while keeping real *line* timing is
   usually right — horizontal is where the subtleties live. But be explicit, because what you shrink
   determines what you can no longer test (§8).

---

## 5. The runtime-mux convention (mock vs real, in one bitstream)

**Every top level instantiates both a synthetic stimulus generator and the real signal path, muxed
at runtime by a mode register, switchable over a UART command byte.** Never `` `ifdef `` build
variants.

Two reasons, both about the agent's loop:

- `ifdef` variants mean two bitstreams and double the synth+PnR cycles.
- Far worse, they create a real risk of **losing track of which variant is currently flashed** — a
  silent, hard-to-debug failure that unattended iteration specifically must avoid.

FPGAs have ample room to hold both paths. Mode switches then happen over serial in milliseconds with
no rebuild and no reflash.

**Run both paths continuously; mux only the output.** If the capture path keeps running while the
mock pattern is displayed, telemetry can answer *"is the external device actually connected and
driving?"* without disturbing what is on screen. That is the first question to ask when a system
shows nothing, and being able to ask it without changing anything is worth the LUTs.

### Choosing the power-on default

The convention says default to mock — correct during bring-up, because it proves the output path
before trusting the input path. But when a design's *purpose* is to run standalone, a default that
waits for a host command cannot do the job.

The resolution that worked was a third setting, **AUTO**, as the power-on default: *show the
synthetic pattern until real data has actually arrived, then switch to real and stay there.* Forced
modes still override absolutely.

This beats both fixed defaults, and the reason is diagnostic rather than aesthetic:

| Power-on default | Input device absent | What you learn |
|---|---|---|
| REAL | black screen | nothing — dead bitstream, bad cable, no power, and "no input" all look the same |
| MOCK | test pattern forever | output path works, but it never does its job unattended |
| **AUTO** | **test pattern** | **output path works; the only missing thing is the input** — and it goes live by itself when that arrives |

Generalise it as: **when a system can't do its job, it should display the most specific true
statement it can about why.**

---

## 6. Build gating — a clean log is not a signoff

Three traps, all of which produce a green build and a broken design.

**Timing analysis does not run without constraints.** With no `.sdc`, the vendor tool emits a
warning that the clock "was determined to be a clock but was not created" and then reports **zero
timing violations — because it checked zero paths.** Every target needs an `.sdc` or its timing
result is meaningless. Have the build script auto-include `src/targets/<name>/<name>.sdc`.

**The tool exits 0 on a design with violated setup paths and writes a bitstream anyway.** One such
build had 15 violated endpoints and an Fmax 11% below the constraint — and *passed its hardware test
at room temperature*, which is the worst possible outcome because it teaches you the wrong lesson.
**Make the build script parse the timing report and fail on any violation**, on a missing report, or
on an analysis that covered 0 paths.

**Warnings are not cosmetic.** Grep the build log for `WARN` after every build and read each one
until you understand it. In one project a genuine language-level defect was reported in plain text
in every single build log for three sessions and was read as noise.

### Reading timing numbers honestly

Check which corner the analysis used. A setup number at *slow / low-voltage / high-temperature* is a
real signoff; at typical it is not.

And beware reading noise as signal. One design closed at 108.423 MHz against a 108 MHz constraint —
36 ps of margin. After *adding* logic it closed at 111.020 MHz. Adding logic cannot make a design
faster, so the only possible conclusion is that **both numbers were placement noise on a
~3% run-to-run spread**, and neither was a dependable margin. If you are within a few percent of the
constraint, you do not have margin; you have luck. Fix it structurally — in that case a combinational
path from a counter through pattern-generation logic to an output register, where the consumer only
needed the value once every 18 cycles and a pipeline register would have removed the problem
permanently.

### Check the pin report's Function column before mapping any signal

Dual-purpose pins are strapped on the PCB and will ignore your constraints. Look for names like
`MODE0`, `MODE1`, `DONE`, `RECONFIG_N`, `READY`, `JTAGSEL_N`. In one project a reset was mapped to a
`MODE0` configuration strap; the board's strapping overrode the internal pull-up, so the pin read low
and **held the entire design in reset for three sessions**. The pin's function was printed in the
report from the very first build.

Corollaries from the same family of trap:

- The clock input may not be a global-clock-capable pin. If it is a PLL reference input instead,
  bypassing the PLL routes your system clock through generic fabric. Fix it by instantiating the
  PLL, not by suppressing the warning.
- Bank voltages reported for banks with **no assigned I/O** are a tool default, not the board's
  supply. Do not conclude your 3.3 V board is 1.8 V from an empty bank.
- Some pins are dedicated configuration pins that the tool refuses to place user I/O on at all,
  until an explicit option releases them. That option is often the only way a design's pin budget
  closes.

---

## 7. Host tooling and telemetry

Once a design is on hardware, the serial link is your entire window into it. Design the telemetry
deliberately.

**Send a fixed-size binary status report, and version it.** A magic byte, a protocol version, then
fields. Bump the version whenever the meaning changes, and have the host **fail loudly on a
mismatch**. This is also the cheapest hardware diagnostic you will ever build: SRAM configuration is
volatile, so a power blip silently reverts the board to whatever is in flash — and the symptom is a
*reply of the wrong length and version*, not a dead link. Dump raw bytes before theorising.

**Report what the design measured off its own output pins, not what its counters intended.** A
counter that generates a signal and a counter that observes it are different instruments; only the
second can catch a generator that is wrong.

**Then cross-check against the host's wall clock.** This is the highest-value trick in the whole
document:

> A mis-locked PLL, a miscounting phase generator, or a design that silently processes half its
> input still produces **perfectly self-consistent internal telemetry**. Only an independent clock
> catches it.

In this project that comparison caught a passthrough that was capturing every *other* frame — 18.9
against 37.7 Hz. Every internal counter agreed with every other internal counter. The host's clock
disagreed with all of them.

**Separate "is the system working" from "is the input present".** Hardware tools must still pass on
a bench with the external device unplugged, or they cannot be used to check the output path on its
own — which is the first bring-up step. Report input-side status; never make it a pass criterion.

**Do not over-fit the pass criterion to your sample data.** A decoder once required `R == G == B`
because every capture so far happened to be greyscale — so "greyscale" got quietly promoted from *a
property of what I measured* to *the definition of correct*. The first genuinely coloured capture,
which was exactly what the tool existed to enable, was rejected as a failure while printing the
correct answer. **An assertion derived from observed data rather than from the specification will
reject the first input that differs from your sample — most confidently at the moment that input is
the interesting one.**

**Give raw counters their denominator.** "26,933 runt clock edges" reads as catastrophic and was
0.0025%, better than a previously accepted rate. A number without its base rate is not a
measurement.

---

## 8. What simulation structurally cannot find

This deserves its own section because it is the failure mode that survives a good process.

A testbench shrinks the problem to run in seconds. **Whatever you shrink, you stop testing.** The
danger is that you keep testing something *adjacent* and mistake it for coverage.

Concretely: a video passthrough's testbench reduced the source to 8 active lines while keeping real
line timing. Reasonable — horizontal is where the subtleties are. But it made the source's *frame
rate* ~325 Hz against a 62 Hz display, when reality is 37.7 Hz against 62 Hz. **The testbench ran the
inverse of the real regime**, and the design's central assumption — that two buffers suffice because
the reader is faster than the writer — was therefore never exercised in the direction where it
mattered. The assumption was wrong, and hardware found it.

Three defences:

1. **Write down which regime the test runs in, in the PASS line itself.** If the summary had said
   "source faster than display" instead of "37.7 Hz-class timing", the gap would have been visible
   every single run.
2. **When hardware finds a bug, reproduce it in simulation before fixing it.** It closes the gap
   permanently and proves the fix. Here that meant a second target with real *frame* timing and
   reduced *active height* — the opposite trade from the first — which reproduced the 50% frame loss
   in 33 seconds.
3. **Write the new test to assert what you want, not what you get.** Watch it fail, fix the design,
   watch it pass. A test written to match current behaviour documents the bug instead of catching
   it.

A fast simulator makes all of this affordable, which is the real argument for §4.

---

## 9. Board and hardware traps worth checking on any project

Generalised from ones that cost real time:

- **Find out what every pin does when your design is not driving it.** External pull-ups win against
  internal pull-downs. In this project a backlight boost converter's enable had a 27 kΩ pull-up to
  3.3 V, so **every bitstream that did not actively drive that pin left the converter enabled** —
  including an unconfigured FPGA. The "safe" state required actively driving it.
- **Ask what a peripheral does with no load.** That same converter took its feedback from a resistor
  in series with the panel's LED string, so with no panel attached the feedback never reached
  threshold and it drove an open circuit at maximum.
- **Some peripherals latch and hold.** An addressable RGB LED keeps its colour indefinitely; tying
  its data line low does not clear it, because a permanently low line is just an endless inter-frame
  gap. The only fix is to *send* the zero frame.
- **PWM on an enable pin is a frequency question, not a yes/no question.** Driving a backlight
  regulator's enable at 1 kHz / 25% duty produced dark output **while the status report said it was
  on** — a fault presenting as working telemetry, the worst combination there is. The conclusion
  written up was "PWM dimming does not work on this board." At 200 Hz it works across the whole
  range and looks good at every level.

  The lesson is not about backlights. **One failing configuration was generalised into a property of
  the hardware**, and that claim then propagated into three documents and shaped a shipped default
  for two sessions. When something fails, ask which variable you actually varied — here the duty was
  swept and the frequency never was. Make the untested variable controllable at runtime and sweep it
  before concluding anything.

  A postscript worth keeping, because it is the honest state of that investigation: the model that
  motivated the fix ("on-time must exceed soft-start") is itself contradicted by the data — the
  working case has a *shorter* on-time than the failing one. The fix works; the explanation for why
  is still unknown, and saying so beats inventing a mechanism that sounds right.
- **When a datasheet section returns nothing from `pdftotext`, the tables are images.** That reads
  exactly like "there is no timing table" rather than like a failed extraction. Read those pages
  visually. Two required pulse-width figures were missing from an analysis for this reason alone,
  and a diagram settled a structural question the totals could only imply.
- **Connector pin-compatibility is not connector compatibility.** Two 40-pin 0.5 mm FFCs can be
  opposite contact types, and no amount of software fixes it — a flipped cable lands supply rails on
  I/O pads. This was flagged in advance as "cannot be settled from the schematic", and it was the
  one thing that was wrong.
- **A signal that must not stall must not be reset.** Holding a clock-phase generator in reset
  stretched its first output period by the whole reset length, violating spec. The converse of the
  usual rule — and it costs you a liveness indicator, since a toggling output is then no longer
  evidence the design is out of reset.
- **Give every register a reset term, especially liveness indicators.** A heartbeat counter with no
  reset blinked happily while every other register sat in reset, making "the bitstream is alive"
  simultaneously true and worthless. **An indicator that cannot distinguish *configured* from
  *running* is worse than no indicator**, because it actively redirects attention.
- **Prefer diagnostics that cannot be misread.** A sticky "≥1 valid byte received since reset" LED
  is good: it only ever goes off→on, needs no timing, and needs no knowledge of what to expect. A
  "current mode" LED is poor: it is a snapshot requiring you to already know the answer.

---

## 10. Debugging discipline

- **Change one variable at a time, and keep a known-good state to fall back to.** When a link
  finally came up it was done as: change pins only, keep baud → verify → change baud → verify. Each
  step had exactly one suspect.
- **Suspect your instrument.** A homemade line probe reported ~590 kbaud for a 115200 link because
  its timer depended on an interrupt that the sampling loop had disabled. The measurement was
  confidently wrong. **Simulation is the authority on what the RTL does**, because it is the only
  place you control every variable. Go back to it the moment the question is "what does my design
  do?"
- **Dump the raw bytes before theorising.** A truncated reply was diagnosed as a brownout caused by
  a boost converter. It was a board reset that had silently reconfigured from flash. The reading
  that settled it was the reply bytes, not any amount of reasoning about power supplies.
- **Do the arithmetic before the panic.** A misread meter (2.66 A, actually ~400 mA) triggered an
  emergency power-down. Six indicator LEDs plus an RGB LED come to ~0.12 A, so LEDs could never have
  explained 2.66 A — but they explain 400 mA fine. One line of estimation would have prevented it.
- **A contradiction is a gift.** Two checks that cannot both be true localise a fault far faster than
  one that is merely false. "Every pixel matched the expected pattern" alongside "the mode register
  says the other source" immediately implicates the *measurement*, not the design. Similarly, "active
  lines = 240" alongside "active clocks per line = 0" can only come from the latch condition, not the
  counter.
- **When something surprising improves, be as suspicious as when it degrades.** Timing that got
  better after adding logic is not good news; it is evidence your previous number meant nothing.

---

## 11. Working with the agent

- **Put the traps in `CLAUDE.md`, not in your head.** The agent re-reads it every session and you do
  not. A "Known gotchas" list with the *symptom*, the *cause* and the *fix* is worth more than any
  amount of tidy prose.
- **State what has and has not been run.** The most damaging thing in a status document is an
  unqualified "done".
- **Ask for the verification plan before the code**, for anything non-trivial. It is much cheaper to
  correct "you're testing the wrong regime" at that point.
- **Have it report outcomes with the numbers attached**, and treat a summary without numbers as
  incomplete.
- **Let it announce long-running work.** Builds and simulations are the parts where a silent agent is
  indistinguishable from a stuck one. Ask for explicit "this is running, expect N minutes"
  statements; it costs nothing and removes all the guessing.
- **Say when hardware is or isn't attached, and what you can see.** The agent cannot look at the
  board. "The panel shows the Prime's screen and it looks perfect" is a measurement it has no other
  way to obtain, and it is often the only remaining unknown.

---

## Appendix — toolchain notes (adapt per vendor)

Vendor tools are usually the signoff path, because bitstream-accurate handling of vendor primitives
(PLLs, block RAM, memory controllers) matters as soon as you use any. Open-source flows are an
excellent fast second opinion. Both are worth having.

Recurring practical traps, phrased generically because every vendor has its own version:

- **Headless invocation often needs environment setup the GUI does the silently** (library and
  framework search paths). The failure mode is that the tool runs, exits 0, and does nothing useful.
  Encode the working invocation in a script; never call the tool directly.
- **Output directories are relative to the working directory, not the script.** `cd` deliberately.
- **Look for a deterministically named output artifact; never glob.** A build script that globbed
  for `*.fs` silently picked up a stale bitstream from a previous build. Also reject an artifact
  whose timestamp predates the current invocation, in case the tool failed silently.
- **Never point a tool at your source constraints file if it rewrites what it is given.** Some
  place-and-route and packing tools annotate the constraints file in place, replacing
  human-authored pin numbers with post-route site names and clobbering the file the vendor flow also
  depends on. Copy it into the build directory first and only ever touch the copy.
- **Device-string forms differ between tools** — full part number with speed grade for one, base
  family for another, and a variant suffix that one tool's database does not have at all. Expect to
  maintain a small mapping, and expect the wrong form to fail in a way that names something else.
- **GUI project files drift.** If the headless scripts generate their own self-contained project,
  say so explicitly, or someone will fix a bug in the file nothing reads.
