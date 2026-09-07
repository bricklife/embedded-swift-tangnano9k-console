import _Volatile

/// Hardware score player @ 0x4000_3000 (see apb_pwm_score.v).
///
/// One voice. Four scores × 64 notes. Duration unit = 8 ms.
enum Sound {
  /// Pitch 0 = rest, 1...48 = C3...B6.
  enum Note: UInt8 {
    case rest = 0
    case c3 = 1
    case cs3 = 2
    case d3 = 3
    case ds3 = 4
    case e3 = 5
    case f3 = 6
    case fs3 = 7
    case g3 = 8
    case gs3 = 9
    case a3 = 10
    case as3 = 11
    case b3 = 12
    case c4 = 13
    case cs4 = 14
    case d4 = 15
    case ds4 = 16
    case e4 = 17
    case f4 = 18
    case fs4 = 19
    case g4 = 20
    case gs4 = 21
    case a4 = 22
    case as4 = 23
    case b4 = 24
    case c5 = 25
    case cs5 = 26
    case d5 = 27
    case ds5 = 28
    case e5 = 29
    case f5 = 30
    case fs5 = 31
    case g5 = 32
    case gs5 = 33
    case a5 = 34
    case as5 = 35
    case b5 = 36
    case c6 = 37
    case cs6 = 38
    case d6 = 39
    case ds6 = 40
    case e6 = 41
    case f6 = 42
    case fs6 = 43
    case g6 = 44
    case gs6 = 45
    case a6 = 46
    case as6 = 47
    case b6 = 48
  }

  private static let noteReg = VolatileMappedRegister<UInt32>(
    unsafeBitPattern: 0x4000_3000
  )
  private static let selReg = VolatileMappedRegister<UInt32>(
    unsafeBitPattern: 0x4000_3004
  )
  private static let ctrlReg = VolatileMappedRegister<UInt32>(
    unsafeBitPattern: 0x4000_3008
  )
  private static let clrReg = VolatileMappedRegister<UInt32>(
    unsafeBitPattern: 0x4000_300c
  )

  static func ms(_ milliseconds: UInt32) -> UInt8 {
    var t = (milliseconds &+ 4) / 8
    if t == 0 { t = 1 }
    if t > 255 { t = 255 }
    return UInt8(truncatingIfNeeded: t)
  }

  static func select(_ score: UInt32) {
    selReg.store(score & 3)
  }

  static func clear() {
    clrReg.store(1)
  }

  static func push(pitch: Note, milliseconds: UInt32) {
    let ticks = ms(milliseconds)
    noteReg.store((UInt32(ticks) << 8) | UInt32(pitch.rawValue))
  }

  static func play(_ score: UInt32) {
    ctrlReg.store((score & 3) | (1 << 8))
  }

  static func stop() {
    ctrlReg.store((1 << 9))
  }
}
