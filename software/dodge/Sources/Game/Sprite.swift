import _Volatile
import Asm

/// GBA-style memory-mapped sprites (plan B).
///
/// - CTRL  @ 0x4000_2000  ENABLE / STAT / INFO
/// - PAL   @ 0x5000_0000  u16[256] RGB565  (16 banks × 16; index 0 = transparent)
/// - TILE  @ 0x5000_1000  64 × 32 B @ 4bpp
/// - OAM   @ 0x5000_4000  N × 4 B packed attributes
///
/// Priority: lower OAM index is drawn in front.
///
/// Bare-metal: do **not** use heap `Array` / temporary `[T]` here (freeze on HW).
/// Prefer tuples, fixed `[N of T]` / `InlineArray`, or `VolatileMappedRegister`.
enum Sprite {
  private static let ctrl = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_2000)
  private static let stat = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_2004)
  private static let info = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_2008)

  static let palBase: UInt = 0x5000_0000
  static let tileBase: UInt = 0x5000_1000
  static let oamBase: UInt = 0x5000_4000

  static var numSprites: UInt32 { info.load() & 0xff }
  static var maxPerLine: UInt32 { (info.load() >> 8) & 0xff }
  static var numTiles: UInt32 { (info.load() >> 16) & 0xff }
  static var bpp: UInt32 { (info.load() >> 24) & 0xf }

  /// Sprite size encoded in OAM `size[1:0]` (bits 31:30).
  /// 16×16 uses tiles `base .. base+3` in 2×2 row-major order.
  /// 32×32 uses tiles `base .. base+15` in 4×4 row-major order.
  enum Size: UInt32 {
    case s8 = 0   // 8×8   (1 tile)
    case s16 = 1  // 16×16 (4 tiles)
    case s32 = 2  // 32×32 (16 tiles)
  }

  /// Pack OAM:
  /// `y[8:0] | x[9:0]<<9 | tile[5:0]<<19 | pal[3:0]<<25 | en<<29 | size[1:0]<<30`
  ///
  /// - X is signed 10-bit (−512…511); partial off left/right is clipped.
  /// - Y is a 9-bit field with modular line test (mod 512): 0…271 are on-screen
  ///   for this 272-line panel, and negative Y (e.g. −3 → 0x1FD) clips at the top.
  /// - `tile` is the **base** tile index (16×16: base..base+3, 32×32: base..base+15).
  static func pack(
    x: Int, y: Int, tile: UInt32, pal: UInt32, enable: Bool,
    size: Size = .s8
  ) -> UInt32 {
    let xi = UInt32(bitPattern: Int32(x)) & 0x3ff
    let yi = UInt32(bitPattern: Int32(y)) & 0x1ff
    let t = tile & 0x3f
    let p = pal & 0xf
    let e: UInt32 = enable ? 1 : 0
    let s = size.rawValue & 0x3
    return yi | (xi << 9) | (t << 19) | (p << 25) | (e << 29) | (s << 30)
  }

  static func setEnable(_ on: Bool) {
    ctrl.store(on ? 1 : 0)
  }

  /// Write OAM entry (volatile word store).
  static func writeOAM(index: UInt32, word: UInt32) {
    VolatileMappedRegister<UInt32>(unsafeBitPattern: oamBase + UInt(index) &* 4)
      .store(word)
    cdcGap()
  }

  /// Palette bank 0..15, color 0..15 (color 0 is transparent in HW).
  /// Uses a word RMW-style store so the transfer is always a legal `sw`
  /// (compilers often merge adjacent halfwords; HW accepts both sh and sw).
  static func writePalette(bank: UInt32, color: UInt32, rgb565: UInt16) {
    writePalette(entry: (bank & 0xf) &* 16 &+ (color & 0xf), rgb565: rgb565)
  }

  /// Flat entry 0..255 (bank*16 + color).
  static func writePalette(entry: UInt32, rgb565: UInt16) {
    let e = entry & 0xff
    // Volatile halfword store. Do not use raw pointee — release DCE drops it.
    VolatileMappedRegister<UInt16>(unsafeBitPattern: palBase + UInt(e) &* 2)
      .store(rgb565)
    cdcGap()
  }

  /// Word store at even entry `entry`/`entry+1` (lo then hi). Preferred path:
  /// one AHB `sw` → ahb_sprite_mem issues two palette CDC writes.
  static func writePaletteWord(entry: UInt32, lo: UInt16, hi: UInt16) {
    let e = entry & 0xfe
    let word = UInt32(lo) | (UInt32(hi) << 16)
    VolatileMappedRegister<UInt32>(unsafeBitPattern: palBase + UInt(e) &* 2)
      .store(word)
    // Space consecutive pal `sw` so the video-domain 3FF sees `spr_wr_req`
    // go low. Timer delay is not used (mtime is unrelated to this CDC).
    cdcGap()
  }

  /// Busy-wait with Asm `nop()` (not the platform timer).
  /// Not inlined — unrolling 16 nops at every tile/pal store overflows the
  /// 24 KiB app region. ~16 calls > HW tile tgap (8 sys cycles).
  @inline(never)
  private static func cdcGap(_ n: UInt32 = 16) {
    var i: UInt32 = 0
    while i < n {
      nop()
      i &+= 1
    }
  }

  /// Write one 8x8 4bpp tile (32 bytes) as eight little-endian words.
  /// Each word is one row: low nibble = leftmost pixel.
  /// Row numbering: row0 = top; even = 0,2,4,6; odd = 1,3,5,7.
  /// One AHB+CDC handshake per row, then a mandatory `cdcGap` (including
  /// after the last row) so the next tile's row0 is not dropped.
  /// See sprite-tile-cdc-investigation.md.
  static func writeTile(
    index: UInt32,
    rows: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
  ) {
    let base = tileBase + UInt(index) &* 32
    storeTileRow(base, rows.0)
    storeTileRow(base &+ 4, rows.1)
    storeTileRow(base &+ 8, rows.2)
    storeTileRow(base &+ 12, rows.3)
    storeTileRow(base &+ 16, rows.4)
    storeTileRow(base &+ 20, rows.5)
    storeTileRow(base &+ 24, rows.6)
    storeTileRow(base &+ 28, rows.7)
  }

  private static func storeTileRow(_ addr: UInt, _ word: UInt32) {
    VolatileMappedRegister<UInt32>(unsafeBitPattern: addr).store(word)
    cdcGap()
  }

  static func clearAllEnabled() {
    let n = numSprites
    var i: UInt32 = 0
    while i < n {
      writeOAM(index: i, word: 0)
      i &+= 1
    }
  }

  static func overflowSticky() -> Bool {
    (stat.load() & 1) != 0
  }

  static func clearOverflow() {
    stat.store(1)
  }
}
