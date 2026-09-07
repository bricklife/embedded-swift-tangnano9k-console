// UART driver for Hazard3 example SoC uart_mini (APB @ 0x4000_4000).
// Matches registers in example_soc/libfpga/peris/uart/uart_regs.h
// and the C demo in example_soc/sw/tangnano9k/main.c.
//
// After UART.configure(), standard Embedded Swift `print(...)` works via putchar.

import _Volatile

enum UART {
  static let baud: UInt32 = 115_200
  static let oversample: UInt32 = 8

  private static let csr = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_4000)
  private static let div = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_4004)
  private static let fstat = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_4008)
  private static let tx = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_400c)

  private static let csrEn: UInt32 = 0x1
  private static let fstatTxFull: UInt32 = 0x100
  private static let fstatTxOver: UInt32 = 0x400
  private static let fstatTxUnder: UInt32 = 0x800
  private static let fstatRxOver: UInt32 = 0x400_0000
  private static let fstatRxUnder: UInt32 = 0x800_0000

  nonisolated(unsafe) private static var initialized = false

  /// Configure baud rate and enable TX. Safe to call more than once.
  static func configure() {
    // Disable while programming divider.
    csr.store(0)

    // baud = clk / ((div_int + div_frac/16) * OVERSAMPLE)
    // div16 = round(clk * 16 / (baud * OVERSAMPLE))
    let div16 =
      (System.clkHz &* 16 &+ (baud &* oversample) / 2) / (baud &* oversample)
    let divInt = (div16 >> 4) & 0x3ff
    let divFrac = div16 & 0xf
    div.store((divInt << 4) | divFrac)

    csr.store(csrEn)

    // Clear sticky FIFO error flags (W1C).
    fstat.store(fstatTxOver | fstatTxUnder | fstatRxOver | fstatRxUnder)
    initialized = true
  }

  /// Blocking put of one byte.
  static func putc(_ c: UInt8) {
    if !initialized {
      configure()
    }
    while (fstat.load() & fstatTxFull) != 0 {}
    tx.store(UInt32(c))
  }

  /// Write a C string (null-terminated). Expands `\n` to `\r\n`.
  static func puts(_ s: StaticString) {
    s.withUTF8Buffer { buf in
      for b in buf {
        if b == 0 { break }
        if b == UInt8(ascii: "\n") {
          putc(UInt8(ascii: "\r"))
        }
        putc(b)
      }
    }
  }

  /// Write a Swift String (for convenience helpers).
  static func write(_ s: String) {
    for ch in s.utf8 {
      if ch == UInt8(ascii: "\n") {
        putc(UInt8(ascii: "\r"))
      }
      putc(ch)
    }
  }

  /// Decimal UInt32 (no heap). Guard div overflow (bad bus reads used to hang).
  static func putDec(_ v: UInt32) {
    if v == 0 {
      putc(UInt8(ascii: "0"))
      return
    }
    var x = v
    var div: UInt32 = 1
    while div <= (UInt32.max / 10) && (x / div) >= 10 {
      div &*= 10
    }
    while true {
      let d = x / div
      putc(UInt8(ascii: "0") &+ UInt8(truncatingIfNeeded: d))
      x %= div
      if div == 1 { break }
      div /= 10
    }
  }
}
