import _Volatile

let KEY = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_c000)

struct Key: OptionSet {
  let rawValue: UInt32

  static let left = Self(rawValue: 1 << 0)
  static let up = Self(rawValue: 1 << 1)
  static let down = Self(rawValue: 1 << 2)
  static let right = Self(rawValue: 1 << 3)
  static let select = Self(rawValue: 1 << 4)
  static let start = Self(rawValue: 1 << 5)
  static let y = Self(rawValue: 1 << 6)
  static let x = Self(rawValue: 1 << 7)
  static let b = Self(rawValue: 1 << 8)
  static let a = Self(rawValue: 1 << 9)

  static func poll() -> Self {
    return Self(rawValue: KEY.load() & 0x03ff)
  }
}
