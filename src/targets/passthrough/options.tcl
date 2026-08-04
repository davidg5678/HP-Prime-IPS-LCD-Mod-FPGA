# Extra gw_sh set_option lines for passthrough (Phase 4). Picked up automatically by
# tools/build/gowin_build.sh when src/targets/<target>/options.tcl exists.
#
# WHY THIS IS REQUIRED, not a tweak:
#
# Phase 3/4 drives the board's RGB LCD FPC connector, which permanently
# reserves twenty FPGA pins (25-42, 48, 77). Subtract those, the BL616 pins and
# the six LEDs, and the 2x20 headers have exactly THIRTEEN pins left. Five of
# those thirteen -- 52, 53, 54, 55, 56 -- are the device's dedicated SSPI
# configuration pins, which gw_sh refuses to place user I/O on by default:
#
#   ERROR (PR2017) 'probe[9]' cannot be placed according to constraint,
#                  for the location is a dedicated pin (SSPI)
#
# Without this option only EIGHT usable pins remain, and the analyser needs
# twelve. So Phase 1's 12 channels and Phase 4's LCD output can only coexist by
# reclaiming the SSPI pins. Sipeed's own examples do the same to reach the I2S
# codec, which is wired to 54/55/56.
#
# Safe here: the board is configured over JTAG (BL616 DirtyJTAG) and its user
# flash hangs off the MSPI pins (59-62), neither of which this touches. The
# option only changes what these pins do in USER mode, after configuration has
# finished -- it cannot make the board harder to program.
set_option -use_sspi_as_gpio 1
