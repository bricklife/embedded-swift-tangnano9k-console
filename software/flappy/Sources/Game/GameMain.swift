import _Volatile

let LCD_VCOUNT = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_1000)
let LCD_ENABLE = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_1004)
let LED = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_8000)

let LCD_W = 480
let LCD_H = 272

let PLAYER_S = 16
let PLAYER_X = 72
// 1/4 px units. Same as hoop / 60fps Flappy clones.
let PHYS = 4
let GRAVITY = 1
let FLAP = -18
let FALL_MAX = 20
let RISE_MAX = 18

let PIPE_W = 32
let PIPE_N = 2
let PIPE_ROWS = 8
let GAP_ROWS = 2
let PIPE_SPEED = 2
let PIPE_SPACING = 240
let FLOOR_Y = 256
let SLOTS_PER_PIPE = 6
let PIPE_SHAFT = UInt32(16)
let PIPE_CAP_TOP = UInt32(32)
let PIPE_CAP_BOT = UInt32(48)

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

@main
struct GameMain {
  static let sfxFlap: UInt32 = 0
  static let sfxDie: UInt32 = 1
  static let sfxPoint: UInt32 = 2
  static let sfxStart: UInt32 = 3

  nonisolated(unsafe) static var isPlaying = false
  nonisolated(unsafe) static var playerY = (FLOOR_Y - PLAYER_S) / 2
  nonisolated(unsafe) static var playerY4 = ((FLOOR_Y - PLAYER_S) / 2) * PHYS
  nonisolated(unsafe) static var playerVY = 0
  nonisolated(unsafe) static var px: [2 of Int] = [0, 0]
  nonisolated(unsafe) static var gapRow: [2 of Int] = [0, 0]
  nonisolated(unsafe) static var rng: UInt32 = 0xACE1

  static func loadSounds() {
    // Flap: one short low blip.
    Sound.select(sfxFlap)
    Sound.clear()
    Sound.push(pitch: .g3, milliseconds: 40)

    // Die: falling thud.
    Sound.select(sfxDie)
    Sound.clear()
    Sound.push(pitch: .g4, milliseconds: 55)
    Sound.push(pitch: .ds4, milliseconds: 55)
    Sound.push(pitch: .c4, milliseconds: 70)
    Sound.push(pitch: .g3, milliseconds: 120)

    // Point: coin sparkle.
    Sound.select(sfxPoint)
    Sound.clear()
    Sound.push(pitch: .c5, milliseconds: 60)
    Sound.push(pitch: .e5, milliseconds: 60)
    Sound.push(pitch: .g5, milliseconds: 60)
    Sound.push(pitch: .c6, milliseconds: 120)

    // Start: cheerful upbeat sting.
    Sound.select(sfxStart)
    Sound.clear()
    Sound.push(pitch: .c5, milliseconds: 80)
    Sound.push(pitch: .e5, milliseconds: 80)
    Sound.push(pitch: .g5, milliseconds: 80)
    Sound.push(pitch: .c6, milliseconds: 100)
    Sound.push(pitch: .g5, milliseconds: 70)
    Sound.push(pitch: .c6, milliseconds: 140)
  }

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

  static func drawGround(_ screen: UnsafeMutablePointer<UInt16>) {
    var y = FLOOR_Y
    while y < LCD_H {
      var x = 0
      while x < LCD_W {
        let c: UInt16
        if y < FLOOR_Y &+ 4 {
          c = Color.grass.rawValue
        } else {
          c = Color.dirt.rawValue
        }
        screen[y * LCD_W + x] = c
        x &+= 1
      }
      y &+= 1
    }
  }

  static func writePipeTiles(base: UInt32, cap: Bool, lipAtTop: Bool = false) {
    var ty = 0
    while ty < 4 {
      var tx = 0
      while tx < 4 {
        var r0: UInt32 = 0
        var r1: UInt32 = 0
        var r2: UInt32 = 0
        var r3: UInt32 = 0
        var r4: UInt32 = 0
        var r5: UInt32 = 0
        var r6: UInt32 = 0
        var r7: UInt32 = 0
        var row = 0
        while row < 8 {
          var word: UInt32 = 0
          var col = 0
          while col < 8 {
            let px = tx &* 8 &+ col
            let py = ty &* 8 &+ row
            // Mario-style lip: cap is 16px tall (half of the 32px cell) and
            // full 32px wide; shaft is inset 2px each side.
            let inCap = cap && (lipAtTop ? py < 16 : py >= 16)
            var nib: UInt32 = 12
            if inCap {
              let openEdge = lipAtTop ? (py < 2) : (py >= 30)
              let innerEdge = lipAtTop ? (py >= 14) : (py < 18)
              if px < 2 || px >= 30 || openEdge || innerEdge {
                nib = 13
              } else if px < 7 {
                nib = 14
              }
            } else if px < 2 || px >= 30 {
              nib = 0
            } else if px < 4 || px >= 28 {
              nib = 13
            } else if px < 8 {
              nib = 14
            } else if px >= 26 {
              nib = 13
            }
            word |= nib &<< (UInt32(col) &* 4)
            col &+= 1
          }
          if row == 0 { r0 = word }
          if row == 1 { r1 = word }
          if row == 2 { r2 = word }
          if row == 3 { r3 = word }
          if row == 4 { r4 = word }
          if row == 5 { r5 = word }
          if row == 6 { r6 = word }
          if row == 7 { r7 = word }
          row &+= 1
        }
        Sprite.writeTile(
          index: base &+ UInt32(ty &* 4 &+ tx),
          rows: (r0, r1, r2, r3, r4, r5, r6, r7)
        )
        tx &+= 1
      }
      ty &+= 1
    }
  }

  // 16x16 Swift-logo bird. Pal index 2 = orange.
  // Tiles 0..3 up, 4..7 neutral, 8..11 down (nearest from up/neutral/down.png).
  static func writeSwiftTiles() {
    // up
    Sprite.writeTile(
      index: 0,
      rows: (
        0x2200_0000,
        0x2222_2000,
        0x2222_2220,
        0x2000_0000,
        0x0000_0000,
        0x2000_0000,
        0x2220_0000,
        0x2222_0000
      )
    )
    Sprite.writeTile(
      index: 1,
      rows: (
        0x0000_0002,
        0x2222_0222,
        0x0222_2222,
        0x0022_2222,
        0x0022_2222,
        0x0022_2222,
        0x0022_2222,
        0x0022_2222
      )
    )
    Sprite.writeTile(
      index: 2,
      rows: (
        0x2220_2200,
        0x0022_0002,
        0x0000_2200,
        0x0000_0000,
        0x0000_0000,
        0x0000_0000,
        0x0000_0000,
        0x0000_0000
      )
    )
    Sprite.writeTile(
      index: 3,
      rows: (
        0x0022_2200,
        0x0022_2200,
        0x0002_2200,
        0x0002_2200,
        0x0000_2220,
        0x0000_0220,
        0x0000_0002,
        0x0000_0000
      )
    )
    // neutral
    Sprite.writeTile(
      index: 4,
      rows: (
        0x0000_0000,
        0x0000_0000,
        0x2200_0000,
        0x2000_0000,
        0x0000_0000,
        0x0000_0000,
        0x2222_2220,
        0x2200_0000
      )
    )
    Sprite.writeTile(
      index: 5,
      rows: (
        0x0000_0000,
        0x0000_0000,
        0x0000_0002,
        0x0000_0222,
        0x0000_2222,
        0x0002_2220,
        0x0022_2222,
        0x2222_2222
      )
    )
    Sprite.writeTile(
      index: 6,
      rows: (
        0x2222_2220,
        0x0000_0000,
        0x0000_0000,
        0x0000_0000,
        0x2200_0000,
        0x2222_0000,
        0x0000_0000,
        0x0000_0000
      )
    )
    Sprite.writeTile(
      index: 7,
      rows: (
        0x0022_2222,
        0x0002_2220,
        0x0002_2220,
        0x0000_2222,
        0x0000_0222,
        0x0000_0002,
        0x0000_0000,
        0x0000_0000
      )
    )
    // down
    Sprite.writeTile(
      index: 8,
      rows: (
        0x0000_0000,
        0x0000_0000,
        0x0000_0000,
        0x0002_0000,
        0x0020_0000,
        0x0202_2000,
        0x2022_0000,
        0x2220_0000
      )
    )
    Sprite.writeTile(
      index: 9,
      rows: (
        0x0000_0000,
        0x0000_0200,
        0x0000_2000,
        0x0002_2000,
        0x0022_0000,
        0x0022_0000,
        0x0222_0002,
        0x0222_2022
      )
    )
    Sprite.writeTile(
      index: 10,
      rows: (
        0x2200_0000,
        0x2000_0000,
        0x0000_0000,
        0x0000_0020,
        0x2222_2200,
        0x2222_2000,
        0x2220_0000,
        0x0000_0000
      )
    )
    Sprite.writeTile(
      index: 11,
      rows: (
        0x0222_2222,
        0x0222_2222,
        0x0222_2222,
        0x0222_2222,
        0x2222_2222,
        0x2222_2222,
        0x2000_0222,
        0x0000_0000
      )
    )
  }

  static func placePipe(_ n: Int, _ x: Int) {
    px[n] = x
    gapRow[n] = 1 + Int(nextRand() % 5)
  }

  static func resetPipes() {
    placePipe(0, LCD_W)
    placePipe(1, LCD_W &+ PIPE_SPACING)
  }

  static func shipTile() -> UInt32 {
    if playerVY <= -PHYS { return 0 }
    if playerVY >= PHYS &* 2 { return 8 }
    return 4
  }

  static func hitPipe(_ n: Int) -> Bool {
    let x = px[n]
    if !overlaps(PLAYER_X, playerY, PLAYER_S, PLAYER_S, x, 0, PIPE_W, FLOOR_Y) {
      return false
    }
    let gapY = gapRow[n] &* PIPE_W
    let gapH = GAP_ROWS &* PIPE_W
    return playerY < gapY || playerY &+ PLAYER_S > gapY &+ gapH
  }

  static func updateSprites() {
    Sprite.writeOAM(
      index: 0,
      word: Sprite.pack(
        x: PLAYER_X, y: playerY, tile: shipTile(), pal: 0, enable: true, size: .s16
      )
    )
    var n = 0
    while n < PIPE_N {
      let base = UInt32(1 &+ n &* SLOTS_PER_PIPE)
      var slot: UInt32 = 0
      var row = 0
      while row < PIPE_ROWS {
        let inGap = row >= gapRow[n] && row < gapRow[n] &+ GAP_ROWS
        if !inGap && slot < UInt32(SLOTS_PER_PIPE) {
          let atBotCap = row &+ 1 == gapRow[n]
          let atTopCap = row == gapRow[n] &+ GAP_ROWS
          let tile: UInt32
          if atTopCap {
            tile = PIPE_CAP_TOP
          } else if atBotCap {
            tile = PIPE_CAP_BOT
          } else {
            tile = PIPE_SHAFT
          }
          Sprite.writeOAM(
            index: base &+ slot,
            word: Sprite.pack(
              x: px[n],
              y: row &* PIPE_W,
              tile: tile,
              pal: 0,
              enable: true,
              size: .s32
            )
          )
          slot &+= 1
        }
        row &+= 1
      }
      while slot < UInt32(SLOTS_PER_PIPE) {
        Sprite.writeOAM(index: base &+ slot, word: 0)
        slot &+= 1
      }
      n &+= 1
    }
  }

  static func main() {
    UART.configure()
    System.delayMs(20)
    UART.puts("Flappy\n")

    LCD_ENABLE.store(0)
    let screen = UnsafeMutablePointer<UInt16>(bitPattern: 0x6000_0000)!
    var i = 0
    while i < LCD_W * LCD_H {
      screen[i] = Color.sky.rawValue
      i &+= 1
    }
    drawGround(screen)

    Sprite.writePaletteWord(entry: 0, lo: 0, hi: Color.white.rawValue)
    Sprite.writePaletteWord(entry: 2, lo: Color.swift.rawValue, hi: Color.swiftDk.rawValue)
    Sprite.writePaletteWord(entry: 4, lo: Color.yellow.rawValue, hi: Color.orange.rawValue)
    Sprite.writePaletteWord(entry: 6, lo: Color.metal.rawValue, hi: Color.red.rawValue)
    Sprite.writePaletteWord(entry: 12, lo: Color.pipe.rawValue, hi: Color.pipeDk.rawValue)
    Sprite.writePaletteWord(entry: 14, lo: Color.pipeHi.rawValue, hi: Color.black.rawValue)

    writeSwiftTiles()
    writePipeTiles(base: PIPE_SHAFT, cap: false)
    writePipeTiles(base: PIPE_CAP_TOP, cap: true, lipAtTop: true)
    writePipeTiles(base: PIPE_CAP_BOT, cap: true, lipAtTop: false)
    Sprite.clearAllEnabled()

    Sprite.setEnable(true)
    resetPipes()
    updateSprites()
    loadSounds()

    waitForVsync()
    LCD_ENABLE.store(1)

    LED.store(0x15)
    waitForKeyPress()
    Sound.play(sfxStart)
    isPlaying = true

    var keys = KeyCounter()
    var blink: UInt32 = 0

    while true {
      waitForVsync()
      keys.poll()
      blink &+= 1
      LED.store((blink & 16) == 0 ? 0x07 : 0x38)

      if isPlaying {
        if keys.up == 1 || keys.a == 1 {
          playerVY = FLAP
          Sound.play(sfxFlap)
        }
        playerVY = clamp(playerVY + GRAVITY, -RISE_MAX, FALL_MAX)
        playerY4 = playerY4 + playerVY
        if playerY4 < 0 {
          playerY4 = 0
          playerVY = 0
        }
        playerY = playerY4 / PHYS
        if playerY &+ PLAYER_S >= FLOOR_Y {
          isPlaying = false
        }

        var n = 0
        while n < PIPE_N && isPlaying {
          px[n] = px[n] - PIPE_SPEED
          if hitPipe(n) {
            isPlaying = false
          }
          // Score once the bird has fully passed the pipe (right edge
          // crossed PLAYER_X), not when the pipe leaves the screen.
          if px[n] &+ PIPE_W <= PLAYER_X
            && px[n] &+ PIPE_W &+ PIPE_SPEED > PLAYER_X
          {
            Sound.play(sfxPoint)
          }
          if px[n] &+ PIPE_W < 0 {
            let other = 1 &- n
            var nx = px[other] &+ PIPE_SPACING
            if nx < LCD_W { nx = LCD_W }
            placePipe(n, nx)
          }
          n &+= 1
        }

        if !isPlaying {
          Sound.play(sfxDie)
          LED.store(0x15)
          updateSprites()
          waitForKeyPress()
          playerY = (FLOOR_Y - PLAYER_S) / 2
          playerY4 = playerY * PHYS
          playerVY = 0
          resetPipes()
          Sound.play(sfxStart)
          isPlaying = true
        }
      }

      updateSprites()
    }
  }
}
