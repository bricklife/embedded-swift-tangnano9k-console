import _Volatile

enum System {
  /// System clock of the Hazard3 example SoC on Tang Nano 9K (PLL → 15 MHz).
  static let clkHz: UInt32 = 15_000_000

  // RISC-V platform timer at 0x4000_0000 (APB).
  // 1 mtime tick = 1 µs (example_soc divides clk by CLK_MHZ).
  // See example_soc/synth_gowin/timer.md
  private static let mtime = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_0008)
  private static let mtimeh = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_000c)

  /// Free-running 64-bit `mtime` (microseconds since reset).
  ///
  /// Reads high then low, and retries if high changed (carry across the
  /// 32-bit boundary while sampling).
  static func readMtime() -> UInt64 {
    var hi: UInt32 = 0
    var lo: UInt32 = 0
    repeat {
      hi = mtimeh.load()
      lo = mtime.load()
    } while hi != mtimeh.load()
    return (UInt64(hi) << 32) | UInt64(lo)
  }

  /// Busy-wait approximately `us` microseconds using the platform timer.
  static func delayUs(_ us: UInt32) {
    let start = readMtime()
    let span = UInt64(us)
    while readMtime() &- start < span {}
  }

  /// Busy-wait approximately `ms` milliseconds using the platform timer.
  static func delayMs(_ ms: UInt32) {
    delayUs(ms &* 1000)
  }
}
