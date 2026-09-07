// Bit-bang SPI SD card (mode 0). Port of sw/sd_boot/sd_spi.c.

enum SDError {
  static let cmd0: UInt8 = 0x02
  static let cmd8: UInt8 = 0x03
  static let acmd41: UInt8 = 0x04
  static let cmd17: UInt8 = 0x05
  static let token: UInt8 = 0x06
}

enum SDSPI {
  nonisolated(unsafe) private static var isSDHC = false

  @inline(__always)
  private static func delayLoops(_ n: UInt32) {
    var i = n
    while i > 0 {
      nop()
      i &-= 1
    }
  }

  @inline(__always)
  private static func sck(_ v: Bool) { GPIO.setBit(GPIO.sckBit, v) }
  @inline(__always)
  private static func mosi(_ v: Bool) { GPIO.setBit(GPIO.mosiBit, v) }
  @inline(__always)
  private static func cs(_ v: Bool) { GPIO.setBit(GPIO.csBit, v) }
  @inline(__always)
  private static func miso() -> Bool { GPIO.getBit(GPIO.misoBit) }

  private static func xfer(_ tx: UInt8) -> UInt8 {
    var rx: UInt8 = 0
    var bit = 7
    while bit >= 0 {
      mosi(((tx &>> bit) & 1) != 0)
      delayLoops(4)
      sck(true)
      delayLoops(4)
      rx = (rx &<< 1) | (miso() ? 1 : 0)
      sck(false)
      delayLoops(2)
      bit &-= 1
    }
    return rx
  }

  private static func deselect() {
    cs(true)
    _ = xfer(0xff)
  }

  private static func select() {
    cs(false)
    _ = xfer(0xff)
  }

  private static func cmd(_ cmd: UInt8, _ arg: UInt32, _ crc: UInt8) -> UInt8 {
    select()
    _ = xfer(0xff)
    _ = xfer(0xff)
    _ = xfer(0x40 | cmd)
    _ = xfer(UInt8(truncatingIfNeeded: arg &>> 24))
    _ = xfer(UInt8(truncatingIfNeeded: arg &>> 16))
    _ = xfer(UInt8(truncatingIfNeeded: arg &>> 8))
    _ = xfer(UInt8(truncatingIfNeeded: arg))
    _ = xfer(crc)

    var r1: UInt8 = 0xff
    var i = 0
    while i < 64 {
      r1 = xfer(0xff)
      if (r1 & 0x80) == 0 { break }
      i &+= 1
    }
    return r1
  }

  /// 0 on success, else SDError code.
  static func initCard() -> UInt8 {
    isSDHC = false
    cs(true)
    sck(false)
    mosi(true)

    delayLoops(50_000)

    var i = 0
    while i < 16 {
      _ = xfer(0xff)
      i &+= 1
    }

    var r = cmd(0, 0, 0x95)
    deselect()
    if r != 0x01 { return SDError.cmd0 }

    r = cmd(8, 0x1AA, 0x87)
    if r == 0x01 {
      _ = xfer(0xff)
      _ = xfer(0xff)
      _ = xfer(0xff)
      _ = xfer(0xff)
      deselect()
    } else {
      deselect()
    }

    var t = 0
    while t < 2000 {
      _ = cmd(55, 0, 0x65)
      deselect()
      r = cmd(41, 0x4000_0000, 0x77)
      deselect()
      if r == 0x00 { break }
      if t == 1999 { return SDError.acmd41 }
      delayLoops(1000)
      t &+= 1
    }

    r = cmd(58, 0, 0xfd)
    if r == 0x00 {
      let b0 = xfer(0xff)
      _ = xfer(0xff)
      _ = xfer(0xff)
      _ = xfer(0xff)
      isSDHC = (b0 & 0x40) != 0
    }
    deselect()
    return 0
  }

  /// Read one 512-byte block into `buf`. 0 on success.
  static func readBlock(_ lba: UInt32, _ buf: UnsafeMutablePointer<UInt8>) -> UInt8 {
    let arg = isSDHC ? lba : (lba &<< 9)
    let r = cmd(17, arg, 0xff)
    if r != 0x00 {
      deselect()
      return SDError.cmd17
    }

    var i = 0
    while i < 100_000 {
      let t = xfer(0xff)
      if t == 0xfe { break }
      if t != 0xff && (t & 0xe0) == 0x00 {
        deselect()
        return SDError.token
      }
      i &+= 1
      if i == 100_000 {
        deselect()
        return SDError.token
      }
    }

    var j = 0
    while j < 512 {
      buf[j] = xfer(0xff)
      j &+= 1
    }
    _ = xfer(0xff)
    _ = xfer(0xff)
    deselect()
    return 0
  }
}

// C nop from Asm module
@_extern(c) func nop()
