// Soft SD bootloader — Embedded Swift.
// Primary: FAT32 root PROG.BIN → 0x2000, jump 0x2040.
// Fallback: on SD failure, UART load (URX. + LE length + payload).

enum BootLayout {
  static let appBase: UInt = 0x0000_2000
  static let appEntry: UInt = 0x0000_2040
  static let appMax: UInt32 = 0x0000_6000  // 24 KiB
}

@main
struct BootMain {
  static func jumpToApp() -> Never {
    GPIO.write(0)
    typealias Entry = @convention(c) () -> Void
    let entry = unsafeBitCast(
      UnsafeMutableRawPointer(bitPattern: BootLayout.appEntry)!,
      to: Entry.self
    )
    entry()
    while true {}
  }

  /// Zero the application SRAM window (0x2000..0x7fff).
  static func clearAppRegion() {
    let appWords = UnsafeMutablePointer<UInt32>(bitPattern: BootLayout.appBase)!
    let wordCount = Int(BootLayout.appMax / 4)
    var i = 0
    while i < wordCount {
      appWords[i] = 0
      i &+= 1
    }
  }

  /// Report SD error then fall back to UART program load.
  static func sdFailToUART(_ code: UInt8) -> Never {
    UART.puts("ERR ")
    UART.putHex8(code)
    UART.puts("\n")
    GPIO.write(0x01)
    loadFromUART()
  }

  /// Host protocol (matches historical prog_loader / uart_prog.py):
  ///   banner "URX." then host sends uint32 LE length + payload bytes.
  /// Payload is written at 0x2000 (max 24 KiB), then jump to 0x2040.
  static func loadFromUART() -> Never {
    // Clear app window *before* URX. so we can stream payload immediately
    // after the length word (avoids RX FIFO overflow while zeroing).
    clearAppRegion()
    UART.flushRX()
    // No newline: host matches the substring "URX."
    UART.puts("URX.")

    var len: UInt32 = 0
    var i = 0
    while i < 4 {
      let b = UART.getc()
      len |= UInt32(b) &<< (i &* 8)
      i &+= 1
    }
    if len > BootLayout.appMax {
      len = BootLayout.appMax
    }

    let app = UnsafeMutablePointer<UInt8>(bitPattern: BootLayout.appBase)!
    var n: UInt32 = 0
    while n < len {
      app[Int(n)] = UART.getc()
      n &+= 1
    }

    UART.puts("\nPRG OK\n")
    UART.waitTxIdle()
    GPIO.write(0x02)
    jumpToApp()
  }

  static func main() {
    // CS high before UART so SD is idle
    GPIO.write(1 &<< GPIO.csBit)

    UART.configure()
    UART.puts("SD..\n")

    let er0 = SDSPI.initCard()
    if er0 != 0 { sdFailToUART(er0) }
    UART.puts("INI.\n")

    let er1 = FAT32.openProgBin()
    if er1 != 0 { sdFailToUART(er1) }
    UART.puts("FAT.\n")

    clearAppRegion()

    let appBytes = UnsafeMutablePointer<UInt8>(bitPattern: BootLayout.appBase)!
    let (er2, _) = FAT32.streamTo(appBytes, BootLayout.appMax)
    if er2 != 0 { sdFailToUART(er2) }

    UART.puts("PRG OK\n")
    UART.waitTxIdle()
    GPIO.write(0x02)
    jumpToApp()
  }
}
