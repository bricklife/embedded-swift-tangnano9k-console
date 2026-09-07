// Soft-SPI GPIO shadow (matches C sd_boot platform.h).
// RMW via software shadow keeps CS/MOSI/SCK coherent.

import _Volatile

enum GPIO {
  static let out = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_8000)
  static let inp = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_c000)

  static let csBit: UInt32 = 8
  static let mosiBit: UInt32 = 9
  static let sckBit: UInt32 = 10
  static let misoBit: UInt32 = 11

  nonisolated(unsafe) private static var shadow: UInt32 = 0

  static func write(_ v: UInt32) {
    shadow = v
    out.store(v)
  }

  static func setBit(_ bit: UInt32, _ value: Bool) {
    let m: UInt32 = 1 &<< bit
    if value {
      shadow |= m
    } else {
      shadow &= ~m
    }
    out.store(shadow)
  }

  static func getBit(_ bit: UInt32) -> Bool {
    (inp.load() & (1 &<< bit)) != 0
  }
}
