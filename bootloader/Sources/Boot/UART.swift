// UART driver for Hazard3 uart_mini (APB @ 0x4000_4000).
// TX + RX for soft boot (UART program-load fallback).

import _Volatile

enum UART {
  static let baud: UInt32 = 115_200
  static let oversample: UInt32 = 8
  static let clkHz: UInt32 = 15_000_000

  private static let csr = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_4000)
  private static let div = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_4004)
  private static let fstat = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_4008)
  private static let tx = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_400c)
  private static let rx = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_4010)

  private static let csrEn: UInt32 = 0x1
  private static let csrBusy: UInt32 = 0x2
  private static let fstatTxFull: UInt32 = 0x100
  private static let fstatRxEmpty: UInt32 = 0x200_0000
  private static let fstatTxOver: UInt32 = 0x400
  private static let fstatTxUnder: UInt32 = 0x800
  private static let fstatRxOver: UInt32 = 0x400_0000
  private static let fstatRxUnder: UInt32 = 0x800_0000

  static func configure() {
    csr.store(0)
    let div16 =
      (clkHz &* 16 &+ (baud &* oversample) / 2) / (baud &* oversample)
    let divInt = (div16 >> 4) & 0x3ff
    let divFrac = div16 & 0xf
    div.store((divInt << 4) | divFrac)
    csr.store(csrEn)
    // Clear sticky FIFO error flags (W1C).
    fstat.store(fstatTxOver | fstatTxUnder | fstatRxOver | fstatRxUnder)
  }

  static func putc(_ c: UInt8) {
    while (fstat.load() & fstatTxFull) != 0 {}
    tx.store(UInt32(c))
  }

  /// Wait until shifter + 2-deep TX FIFO are idle. Call before jumpToApp
  /// so the app's UART.configure() cannot abort the last banner bytes.
  static func waitTxIdle() {
    while (csr.load() & csrBusy) != 0 {}
  }

  /// Blocking read of one byte from RX FIFO.
  static func getc() -> UInt8 {
    while (fstat.load() & fstatRxEmpty) != 0 {}
    return UInt8(truncatingIfNeeded: rx.load())
  }

  /// Drain any bytes already in the RX FIFO (noise before URX handshake).
  static func flushRX() {
    while (fstat.load() & fstatRxEmpty) == 0 {
      _ = rx.load()
    }
  }

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

  static func putHex8(_ v: UInt8) {
    let hex: StaticString = "0123456789ABCDEF"
    hex.withUTF8Buffer { digits in
      putc(digits[Int(v >> 4)])
      putc(digits[Int(v & 0xf)])
    }
  }
}
