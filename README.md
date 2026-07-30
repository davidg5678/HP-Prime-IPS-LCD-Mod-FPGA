# HP Prime LCD

Reverse-engineering the HP Prime calculator's LCD panel signal on a Sipeed Tang Nano 20K FPGA,
in four phases: capture the serial-RGB signal as a logic analyzer, decode/render it offline in
Python, drive a physical parallel-RGB LCD, then feed the live captured feed into that driver.

- **`CLAUDE.md`** — toolchain paths, build/test/flash commands, and repo conventions.
- **`docs/architecture.md`** — signal theory, toolchain tradeoffs, and the full phase roadmap.
- **`PROGRESS.md`** — current status; what's built, what's verified, what's next.
- **`boards/tangnano20k/pinout.md`** — board pin reference.

Quick start: `make check-env`, then `make sim`, then `make build`. See `CLAUDE.md` for the full
command table.
