// Temporary Arduino Uno UART bridge (proto-phase-1 bring-up workaround).
// Relays raw bytes between the Mac (hardware Serial, over the 16u2/USB) and
// the FPGA (SoftwareSerial on D2/D3), since the Uno's single hardware UART
// is already committed to the USB link. See boards/tangnano20k/arduino_bridge.md.
//
// D2 = SoftwareSerial RX <- FPGA pin 72 (uart_tx), direct wire
// D3 = SoftwareSerial TX -> FPGA pin 71 (uart_rx), through the 1k/2k divider
//
// The two links deliberately run at DIFFERENT baud rates.
//
// SoftwareSerial is bit-banged: its RX ISR holds interrupts disabled for a
// whole byte time, which blocks the hardware USART's UDRE interrupt and stalls
// outgoing TX. Running both sides at 115200 therefore makes the outbound rate
// strictly lower than the inbound rate, and a sustained FPGA burst overruns the
// 64-byte buffer no matter how large it is -- measured as a dropped byte every
// ~116 bytes. Slowing only the bit-banged side gives the relay 3x headroom.
//
// USB_BAUD must match BAUD in serial_selftest.py / arduino_bridge_selftest.py.
// FPGA_BAUD must match the BAUD localparam in bringup_selftest_top.v.

#include <SoftwareSerial.h>

SoftwareSerial fpgaSerial(2, 3); // RX, TX
const long USB_BAUD  = 115200;   // hardware UART, via the 16u2 to the Mac
const long FPGA_BAUD = 38400;    // bit-banged, to the FPGA

void setup() {
  Serial.begin(USB_BAUD);
  fpgaSerial.begin(FPGA_BAUD);
}

void loop() {
  if (Serial.available()) {
    fpgaSerial.write((uint8_t)Serial.read());
  }
  if (fpgaSerial.available()) {
    Serial.write((uint8_t)fpgaSerial.read());
  }
}
