// Minimal FAT32: open root PROG.BIN and stream bytes.
// Port of sw/sd_boot/fat32.c

enum FATError {
  static let bpb: UInt8 = 0x10
  static let noFile: UInt8 = 0x11
  static let sd: UInt8 = 0x12
  static let chain: UInt8 = 0x13
}

enum FAT32 {
  /// BSS buffer provided by Asm/sector.c
  private static var sec: UnsafeMutablePointer<UInt8> { sd_sector_ptr() }

  nonisolated(unsafe) private static var partLba0: UInt32 = 0
  nonisolated(unsafe) private static var reserved: UInt16 = 0
  nonisolated(unsafe) private static var numFATs: UInt8 = 0
  nonisolated(unsafe) private static var fatSz: UInt32 = 0
  nonisolated(unsafe) private static var spc: UInt8 = 0
  nonisolated(unsafe) private static var rootCl: UInt32 = 0
  nonisolated(unsafe) private static var fatBegin: UInt32 = 0
  nonisolated(unsafe) private static var clBegin: UInt32 = 0
  nonisolated(unsafe) private static var firstCluster: UInt32 = 0
  nonisolated(unsafe) private static var fileSize: UInt32 = 0

  @inline(__always)
  private static func rd16(_ p: UnsafePointer<UInt8>) -> UInt32 {
    UInt32(p[0]) | (UInt32(p[1]) &<< 8)
  }

  @inline(__always)
  private static func rd32(_ p: UnsafePointer<UInt8>) -> UInt32 {
    rd16(p) | (rd16(p.advanced(by: 2)) &<< 16)
  }

  @inline(__always)
  private static func clToLba(_ cl: UInt32) -> UInt32 {
    clBegin &+ (cl &- 2) &* UInt32(spc)
  }

  private static func readFATEntry(_ cl: UInt32, _ next: inout UInt32) -> UInt8 {
    let fatOff = cl &* 4
    let lba = fatBegin &+ (fatOff / 512)
    let off = Int(fatOff % 512)
    if SDSPI.readBlock(lba, sec) != 0 { return FATError.sd }
    next = rd32(sec.advanced(by: off)) & 0x0fff_ffff
    return 0
  }

  /// Open root PROG.BIN. 0 = ok.
  static func openProgBin() -> UInt8 {
    if SDSPI.readBlock(0, sec) != 0 { return FATError.sd }
    if sec[510] != 0x55 || sec[511] != 0xAA { return FATError.bpb }

    partLba0 = rd32(sec.advanced(by: 0x1C6))

    if SDSPI.readBlock(partLba0, sec) != 0 { return FATError.sd }
    if sec[510] != 0x55 || sec[511] != 0xAA { return FATError.bpb }
    if !(sec[0x52] == UInt8(ascii: "F")
      && sec[0x53] == UInt8(ascii: "A")
      && sec[0x54] == UInt8(ascii: "T"))
    {
      return FATError.bpb
    }

    reserved = UInt16(rd16(sec.advanced(by: 0x0E)))
    numFATs = sec[0x10]
    spc = sec[0x0D]
    fatSz = rd32(sec.advanced(by: 0x24))
    rootCl = rd32(sec.advanced(by: 0x2C))
    if spc == 0 || numFATs == 0 || fatSz == 0 { return FATError.bpb }

    fatBegin = partLba0 &+ UInt32(reserved)
    clBegin = fatBegin &+ UInt32(numFATs) &* fatSz

    var cl = rootCl
    var guardCount = 0
    while guardCount < 4096 {
      var s: UInt8 = 0
      while s < spc {
        if SDSPI.readBlock(clToLba(cl) &+ UInt32(s), sec) != 0 {
          return FATError.sd
        }
        var i = 0
        while i < 512 {
          let e = sec.advanced(by: i)
          if e[0] == 0x00 { return FATError.noFile }
          if e[0] == 0xE5 {
            i &+= 32
            continue
          }
          if (e[11] & 0x0F) == 0x0F {
            i &+= 32
            continue
          }
          if (e[11] & 0x18) != 0 {
            i &+= 32
            continue
          }
          // PROG.BIN
          if e[0] == UInt8(ascii: "P") && e[1] == UInt8(ascii: "R")
            && e[2] == UInt8(ascii: "O") && e[3] == UInt8(ascii: "G")
            && e[4] == UInt8(ascii: " ") && e[5] == UInt8(ascii: " ")
            && e[6] == UInt8(ascii: " ") && e[7] == UInt8(ascii: " ")
            && e[8] == UInt8(ascii: "B") && e[9] == UInt8(ascii: "I")
            && e[10] == UInt8(ascii: "N")
          {
            let hi = rd16(e.advanced(by: 20))
            let lo = rd16(e.advanced(by: 26))
            firstCluster = (hi &<< 16) | lo
            fileSize = rd32(e.advanced(by: 28))
            if firstCluster < 2 { return FATError.noFile }
            return 0
          }
          i &+= 32
        }
        s &+= 1
      }
      var next: UInt32 = 0
      let er = readFATEntry(cl, &next)
      if er != 0 { return er }
      if next >= 0x0fff_fff8 { return FATError.noFile }
      if next < 2 { return FATError.chain }
      cl = next
      guardCount &+= 1
    }
    return FATError.chain
  }

  /// Stream file into dst[0..<maxBytes]. Returns (error, written).
  static func streamTo(
    _ dst: UnsafeMutablePointer<UInt8>,
    _ maxBytes: UInt32
  ) -> (UInt8, UInt32) {
    var remain = fileSize
    if remain > maxBytes { remain = maxBytes }
    var written: UInt32 = 0
    var cl = firstCluster

    while remain > 0 {
      var s: UInt8 = 0
      while s < spc && remain > 0 {
        if SDSPI.readBlock(clToLba(cl) &+ UInt32(s), sec) != 0 {
          return (FATError.sd, written)
        }
        let n = remain > 512 ? UInt32(512) : remain
        var i: UInt32 = 0
        while i < n {
          dst[Int(written &+ i)] = sec[Int(i)]
          i &+= 1
        }
        written &+= n
        remain &-= n
        s &+= 1
      }
      if remain == 0 { break }
      var next: UInt32 = 0
      let er = readFATEntry(cl, &next)
      if er != 0 { return (er, written) }
      if next >= 0x0fff_fff8 { break }
      if next < 2 { return (FATError.chain, written) }
      cl = next
    }
    return (0, written)
  }
}

@_extern(c) func sd_sector_ptr() -> UnsafeMutablePointer<UInt8>
