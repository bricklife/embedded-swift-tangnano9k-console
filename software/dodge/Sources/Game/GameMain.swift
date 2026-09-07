import _Volatile

let LCD_VCOUNT = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_1000)
let LCD_ENABLE = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_1004)
let LED = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_8000)

let LCD_W = 480
let LCD_H = 272

let PLAYER_S = 32
let HAZARD_S = 16
let HAZARD_N = 7
let PLAYER_SPEED = 3
let HAZARD_SPEED = 2
let PLAYER_Y = LCD_H - PLAYER_S - 4
let STAR_N = 120
let ROCK_KINDS = 4

func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
  if v < lo { return lo }
  if v > hi { return hi }
  return v
}

func overlaps(
  _ ax: Int, _ ay: Int, _ aw: Int, _ ah: Int,
  _ bx: Int, _ by: Int, _ bw: Int, _ bh: Int
) -> Bool {
  ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by
}

func writeEmptyTile(_ index: UInt32) {
  Sprite.writeTile(index: index, rows: (0, 0, 0, 0, 0, 0, 0, 0))
}

@main
struct GameMain {
  nonisolated(unsafe) static var isPlaying = false
  nonisolated(unsafe) static var playerX = (LCD_W - PLAYER_S) / 2
  nonisolated(unsafe) static var hzX: [7 of Int] = [0, 0, 0, 0, 0, 0, 0]
  nonisolated(unsafe) static var hzY: [7 of Int] = [0, 0, 0, 0, 0, 0, 0]
  nonisolated(unsafe) static var hzKind: [7 of UInt32] = [0, 0, 0, 0, 0, 0, 0]
  nonisolated(unsafe) static var rng: UInt32 = 0xACE1

  static func waitForVsync() {
    while LCD_VCOUNT.load() >= UInt32(LCD_H) {}
    while LCD_VCOUNT.load() < UInt32(LCD_H) {}
  }

  static func waitForKeyPress() {
    while Key.poll().isPressingAny {
      waitForVsync()
    }
    while !Key.poll().isPressingAny {
      waitForVsync()
    }
    while Key.poll().isPressingAny {
      waitForVsync()
    }
  }

  static func nextRand() -> UInt32 {
    rng = rng &* 1_103_515_245 &+ 12_345
    return rng
  }

  static func drawStarfield(_ screen: UnsafeMutablePointer<UInt16>) {
    let skyH = LCD_H
    var n = 0
    while n < STAR_N {
      let r = nextRand()
      let x = Int(r % UInt32(LCD_W))
      let y = Int((r &>> 16) % UInt32(skyH))
      let bright = (r &>> 8) & 3
      var c = Color.dim.rawValue
      if bright == 0 {
        c = Color.white.rawValue
      } else if bright == 1 {
        c = Color.gray.rawValue
      }
      screen[y * LCD_W + x] = c
      if bright == 0 && x &+ 1 < LCD_W {
        screen[y * LCD_W + x &+ 1] = Color.gray.rawValue
      }
      if bright == 0 && y &+ 1 < skyH {
        screen[(y &+ 1) * LCD_W + x] = Color.dim.rawValue
      }
      n &+= 1
    }
  }

  static func writeShipTiles() {
    writeEmptyTile(0)
    writeEmptyTile(3)
    writeEmptyTile(8)
    writeEmptyTile(11)
    writeEmptyTile(12)
    writeEmptyTile(15)
    Sprite.writeTile(
      index: 1,
      rows: (
        0x1000_0000,
        0x2100_0000,
        0x2210_0000,
        0x2221_0000,
        0x2222_1000,
        0x4222_1000,
        0x4222_2100,
        0x2222_2210
      )
    )
    Sprite.writeTile(
      index: 2,
      rows: (
        0x0000_0001,
        0x0000_0012,
        0x0000_0122,
        0x0000_1222,
        0x0001_2222,
        0x0001_2224,
        0x0012_2224,
        0x0122_2222
      )
    )
    Sprite.writeTile(
      index: 4,
      rows: (
        0x6600_0000,
        0x2660_0000,
        0x2266_0000,
        0x2226_6000,
        0x2226_6000,
        0x2266_0000,
        0x2660_0000,
        0x6600_0000
      )
    )
    Sprite.writeTile(
      index: 5,
      rows: (
        0x4422_2210,
        0x2222_2221,
        0x2222_2221,
        0x2222_2221,
        0x2222_2221,
        0x2222_2221,
        0x2222_2210,
        0x2222_2100
      )
    )
    Sprite.writeTile(
      index: 6,
      rows: (
        0x0122_2244,
        0x1222_2222,
        0x1222_2222,
        0x1222_2222,
        0x1222_2222,
        0x1222_2222,
        0x0122_2222,
        0x0012_2222
      )
    )
    Sprite.writeTile(
      index: 7,
      rows: (
        0x0000_0066,
        0x0000_0662,
        0x0000_6622,
        0x0006_6222,
        0x0006_6222,
        0x0000_6622,
        0x0000_0662,
        0x0000_0066
      )
    )
    Sprite.writeTile(
      index: 9,
      rows: (
        0x2222_2100,
        0x2222_1000,
        0x2221_0000,
        0x2255_0000,
        0x0575_0000,
        0x0750_0000,
        0x0500_0000,
        0
      )
    )
    Sprite.writeTile(
      index: 10,
      rows: (
        0x0012_2222,
        0x0001_2222,
        0x0000_1222,
        0x0000_5522,
        0x0000_5750,
        0x0000_0570,
        0x0000_0050,
        0
      )
    )
    writeEmptyTile(13)
    writeEmptyTile(14)
  }

  static func writeRockTiles() {
    // 16: round boulder with crater
    Sprite.writeTile(
      index: 16,
      rows: (
        0x9988_0000,
        0xA999_8000,
        0xA999_8800,
        0xBAA9_9980,
        0xBBAA_9988,
        0x888A_A998,
        0xBB88_AA98,
        0x00B8_9A98
      )
    )
    Sprite.writeTile(
      index: 17,
      rows: (
        0x0000_0088,
        0x0008_899A,
        0x0088_99AA,
        0x0899_AAB9,
        0x8899_AABB,
        0x899A_A888,
        0x89AA_88BB,
        0x89A9_8B00
      )
    )
    Sprite.writeTile(
      index: 18,
      rows: (
        0xBB88_9A98,
        0x899A_A998,
        0xA999_AA88,
        0xAAAA_A998,
        0x9AAA_9980,
        0x9999_8800,
        0x8888_8000,
        0x0888_0000
      )
    )
    Sprite.writeTile(
      index: 19,
      rows: (
        0x89A9_88BB,
        0x899A_A998,
        0x889A_A999,
        0x89AA_AAAA,
        0x0899_AAA9,
        0x0088_9998,
        0x0008_8888,
        0x0000_8880
      )
    )
    // 20: pointed shard
    Sprite.writeTile(
      index: 20,
      rows: (
        0x9800_0000,
        0xA980_0000,
        0xAA98_0000,
        0xBAA9_8000,
        0x9AA9_9800,
        0x89A9_A980,
        0x889A_AA98,
        0x8889_AA99
      )
    )
    Sprite.writeTile(
      index: 21,
      rows: (
        0x0000_0008,
        0x0000_089A,
        0x0000_89AA,
        0x0008_9AAB,
        0x0089_9AA9,
        0x089A_9A98,
        0x89AA_A988,
        0x99AA_9888
      )
    )
    Sprite.writeTile(
      index: 22,
      rows: (
        0x8888_9AA9,
        0x0888_89AA,
        0x0088_889A,
        0x0008_8889,
        0x0000_8888,
        0x0000_0888,
        0x0000_0088,
        0
      )
    )
    Sprite.writeTile(
      index: 23,
      rows: (
        0x9AA9_8888,
        0xAA98_8880,
        0xA988_8800,
        0x9888_8000,
        0x8888_0000,
        0x8880_0000,
        0x8800_0000,
        0
      )
    )
    // 24: wide potato
    Sprite.writeTile(
      index: 24,
      rows: (
        0x9988_8000,
        0xAA99_8800,
        0xBAAA_9980,
        0x9BAA_A998,
        0x89AA_AA99,
        0x8899_9AA9,
        0x8888_99AA,
        0x0888_899A
      )
    )
    Sprite.writeTile(
      index: 25,
      rows: (
        0x0008_8899,
        0x0088_99AA,
        0x0899_AAAB,
        0x899A_AAB9,
        0x99AA_AA98,
        0x9AA9_9988,
        0xAA99_8888,
        0xA998_8880
      )
    )
    Sprite.writeTile(
      index: 26,
      rows: (
        0x0088_8899,
        0x0888_899A,
        0x8888_99AA,
        0x8889_9AA9,
        0x0888_9A98,
        0x0088_8980,
        0x0008_8800,
        0
      )
    )
    Sprite.writeTile(
      index: 27,
      rows: (
        0x9988_8800,
        0xA998_8880,
        0xAA99_8888,
        0x9AA9_9888,
        0x89A9_8880,
        0x0898_8800,
        0x0088_8000,
        0
      )
    )
    // 28: jagged split
    Sprite.writeTile(
      index: 28,
      rows: (
        0x8A80_0000,
        0x9AA8_0000,
        0x9BAA_8000,
        0x89AA_9800,
        0x889A_A980,
        0x0889_AA98,
        0x0088_9AA9,
        0x0008_89AA
      )
    )
    Sprite.writeTile(
      index: 29,
      rows: (
        0x0000_08A8,
        0x0000_8AA9,
        0x0008_AAB9,
        0x0089_AA98,
        0x089A_A988,
        0x89AA_9880,
        0x9AA9_8800,
        0xAA98_8000
      )
    )
    Sprite.writeTile(
      index: 30,
      rows: (
        0x0000_889A,
        0x0008_899A,
        0x0088_9AA9,
        0x0889_AA98,
        0x889A_A980,
        0x89AA_9800,
        0x9AA8_0000,
        0x8A80_0000
      )
    )
    Sprite.writeTile(
      index: 31,
      rows: (
        0xA988_0000,
        0xA998_8000,
        0x9AA9_8800,
        0x89AA_9880,
        0x089A_A988,
        0x0089_AA98,
        0x0008_AAB9,
        0x0000_8A80
      )
    )
  }

  static func placeHazard(_ n: Int, _ y: Int) {
    hzY[n] = y
    hzX[n] = Int(nextRand() % UInt32(LCD_W - HAZARD_S))
    hzKind[n] = nextRand() % UInt32(ROCK_KINDS)
  }

  static func resetHazards() {
    var n = 0
    while n < HAZARD_N {
      placeHazard(n, -HAZARD_S - n * 36)
      n &+= 1
    }
  }

  static func hitsPlayer() -> Bool {
    let px = playerX + 6
    let py = PLAYER_Y + 4
    var n = 0
    while n < HAZARD_N {
      if overlaps(px, py, 20, 24, hzX[n], hzY[n], HAZARD_S, HAZARD_S) {
        return true
      }
      n &+= 1
    }
    return false
  }

  static func updateSprites() {
    Sprite.writeOAM(
      index: 0,
      word: Sprite.pack(
        x: playerX, y: PLAYER_Y, tile: 0, pal: 0, enable: true, size: .s32
      )
    )
    var n: UInt32 = 0
    while n < UInt32(HAZARD_N) {
      Sprite.writeOAM(
        index: n &+ 1,
        word: Sprite.pack(
          x: hzX[Int(n)],
          y: hzY[Int(n)],
          tile: 16 &+ hzKind[Int(n)] &* 4,
          pal: 0,
          enable: true,
          size: .s16
        )
      )
      n &+= 1
    }
  }

  static func main() {
    UART.configure()
    System.delayMs(20)
    UART.puts("Dodge\n")

    LCD_ENABLE.store(0)
    let screen = UnsafeMutablePointer<UInt16>(bitPattern: 0x6000_0000)!
    var i = 0
    while i < LCD_W * LCD_H {
      screen[i] = Color.black.rawValue
      i &+= 1
    }
    drawStarfield(screen)

    Sprite.writePaletteWord(entry: 0, lo: 0, hi: Color.white.rawValue)
    Sprite.writePaletteWord(entry: 2, lo: Color.hull.rawValue, hi: Color.hullDark.rawValue)
    Sprite.writePaletteWord(entry: 4, lo: Color.yellow.rawValue, hi: Color.orange.rawValue)
    Sprite.writePaletteWord(entry: 6, lo: Color.metal.rawValue, hi: Color.red.rawValue)
    Sprite.writePaletteWord(entry: 8, lo: Color.rockDk.rawValue, hi: Color.rockMd.rawValue)
    Sprite.writePaletteWord(entry: 10, lo: Color.rockLt.rawValue, hi: Color.rockHi.rawValue)

    writeShipTiles()
    writeRockTiles()

    Sprite.setEnable(true)
    resetHazards()
    updateSprites()

    waitForVsync()
    LCD_ENABLE.store(1)

    //UART.puts("press any key\n")
    LED.store(0x15)
    waitForKeyPress()
    isPlaying = true

    var keys = KeyCounter()
    var blink: UInt32 = 0

    while true {
      waitForVsync()
      keys.poll()
      blink &+= 1
      LED.store((blink & 16) == 0 ? 0x07 : 0x38)

      if keys.left > 0 {
        playerX = clamp(playerX - PLAYER_SPEED, 0, LCD_W - PLAYER_S)
      }
      if keys.right > 0 {
        playerX = clamp(playerX + PLAYER_SPEED, 0, LCD_W - PLAYER_S)
      }

      if isPlaying {
        var n = 0
        while n < HAZARD_N {
          hzY[n] = hzY[n] + HAZARD_SPEED
          if hzY[n] > LCD_H {
            placeHazard(n, -HAZARD_S - Int(nextRand() % 48))
          }
          n &+= 1
        }

        if hitsPlayer() {
          isPlaying = false
          //UART.puts("hit — press any key\n")
          LED.store(0x15)
          updateSprites()
          waitForKeyPress()
          playerX = (LCD_W - PLAYER_S) / 2
          resetHazards()
          isPlaying = true
        }
      }

      updateSprites()
    }
  }
}
