import _Volatile

let LCD_VCOUNT = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_1000)
let LCD_ENABLE = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_1004)
let LCD_FRAME = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_1008)
let LED = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x4000_8000)

let LCD_W = 480
let LCD_H = 272

let PADDLE_W = 8
let PADDLE_H = 32
let BALL_S = 8
let LEFT_X = 16
let RIGHT_X = LCD_W - 16 - PADDLE_W
let PADDLE_SPEED = 3
let BALL_SPEED = 4

func overlaps(
  _ ax: Int,
  _ ay: Int,
  _ aw: Int,
  _ ah: Int,
  _ bx: Int,
  _ by: Int,
  _ bw: Int,
  _ bh: Int
) -> Bool {
  ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by
}

struct GameState {
  static let midX = (LCD_W - 8) / 2
  static let midY = (LCD_H - PADDLE_H) / 2

  var isPlaying: Bool
  var leftY: Int
  var rightY: Int
  var ballX: Int
  var ballY: Int
  var ballDX: Int
  var ballDY: Int

  init(
    isPlaying: Bool = false,
    leftY: Int = (LCD_H - PADDLE_H) / 2,
    rightY: Int = (LCD_H - PADDLE_H) / 2,
    ballX: Int = (LCD_W - 8) / 2,
    ballY: Int = (LCD_H - 8) / 2,
    ballDX: Int = BALL_SPEED,
    ballDY: Int = BALL_SPEED
  ) {
    self.isPlaying = isPlaying
    self.leftY = leftY
    self.rightY = rightY
    self.ballX = ballX
    self.ballY = ballY
    self.ballDX = ballDX
    self.ballDY = ballDY
  }
}

@main
struct GameMain {
  static let sfxPaddle: UInt32 = 0
  static let sfxWall: UInt32 = 1
  static let sfxGoal: UInt32 = 2
  static let sfxServe: UInt32 = 3

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
  }

  nonisolated(unsafe) static var state = GameState()

  static func loadSounds() {
    // Paddle hit: bright ping.
    Sound.select(sfxPaddle)
    Sound.clear()
    Sound.push(pitch: .c5, milliseconds: 40)
    Sound.push(pitch: .e5, milliseconds: 50)
    Sound.push(pitch: .g5, milliseconds: 70)

    // Wall bounce: short tick.
    Sound.select(sfxWall)
    Sound.clear()
    Sound.push(pitch: .g4, milliseconds: 35)
    Sound.push(pitch: .c5, milliseconds: 45)

    // Goal: descending buzz.
    Sound.select(sfxGoal)
    Sound.clear()
    Sound.push(pitch: .a4, milliseconds: 60)
    Sound.push(pitch: .f4, milliseconds: 60)
    Sound.push(pitch: .d4, milliseconds: 70)
    Sound.push(pitch: .a3, milliseconds: 140)

    // Serve: rising ready sting.
    Sound.select(sfxServe)
    Sound.clear()
    Sound.push(pitch: .c4, milliseconds: 60)
    Sound.push(pitch: .e4, milliseconds: 60)
    Sound.push(pitch: .g4, milliseconds: 60)
    Sound.push(pitch: .c5, milliseconds: 110)
  }

  static func writePaddle(index: UInt32, x: Int, y: Int) {
    Sprite.writeOAM(
      index: index,
      word: Sprite.pack(x: x, y: y, tile: 4, pal: 0, enable: true, size: .s32)
    )
  }

  static func updateSprites() {
    Sprite.writeOAM(
      index: 0,
      word: Sprite.pack(x: state.ballX, y: state.ballY, tile: 0, pal: 0, enable: true)
    )
    writePaddle(index: 1, x: LEFT_X, y: state.leftY)
    writePaddle(index: 2, x: RIGHT_X, y: state.rightY)
  }

  static func main() {
    UART.configure()
    System.delayMs(20)
    print("Pong")

    LCD_ENABLE.store(0)

    let screen = UnsafeMutablePointer<UInt16>(bitPattern: 0x6000_0000)!
    var i = 0
    while i < LCD_W * LCD_H {
      screen[i] = Color.orange.rawValue
      i &+= 1
    }
    var y = 0
    while y < LCD_H {
      if (y & 8) == 0 {
        screen[y * LCD_W + 239] = Color.gray.rawValue
        screen[y * LCD_W + 240] = Color.gray.rawValue
      }
      y &+= 1
    }
    // White bird only (skip orange fill + PNG corner whites).
    let logoX = (LCD_W - imageWidth) / 2
    let logoY = (LCD_H - imageHeight) / 2
    let logoR2 = 46 * 46
    var ly = 0
    while ly < imageHeight {
      var lx = 0
      while lx < imageWidth {
        let dx = lx - imageWidth / 2
        let dy = ly - imageHeight / 2
        if dx * dx + dy * dy <= logoR2 {
          let pix = imagePixels[ly * imageWidth + lx]
          let g = (pix &>> 5) & 0x3f
          if g >= 40 {
            screen[(ly + logoY) * LCD_W + lx + logoX] = pix
          }
        }
        lx &+= 1
      }
      ly &+= 1
    }

    // pal0: 0=clear, 1=cream, 2=cocoa, 3=umber
    Sprite.writePaletteWord(entry: 0, lo: 0, hi: Color.cream.rawValue)
    Sprite.writePaletteWord(entry: 2, lo: Color.cocoa.rawValue, hi: Color.umber.rawValue)

    // Tile 0: 8x8 ball (2=cocoa, 1=cream highlight)
    Sprite.writeTile(
      index: 0,
      rows: (
        0x0022_2200,
        0x0222_2220,
        0x2222_1122,
        0x2222_1122,
        0x2222_2222,
        0x2222_2222,
        0x0222_2220,
        0x0022_2200
      )
    )

    // Tiles 4..19: 32x32 paddle, leftmost 8px solid, rest clear (4x4 of 8x8)
    let padTop: UInt32 = 0x0111_1111
    let padRow: UInt32 = 0x3111_1111
    let padLast: UInt32 = 0x3333_3330
    let empty: UInt32 = 0
    let emptyRows = (empty, empty, empty, empty, empty, empty, empty, empty)
    Sprite.writeTile(index: 4, rows: (padTop, padRow, padRow, padRow, padRow, padRow, padRow, padRow))
    Sprite.writeTile(index: 8, rows: (padRow, padRow, padRow, padRow, padRow, padRow, padRow, padRow))
    Sprite.writeTile(index: 12, rows: (padRow, padRow, padRow, padRow, padRow, padRow, padRow, padRow))
    Sprite.writeTile(index: 16, rows: (padRow, padRow, padRow, padRow, padRow, padRow, padRow, padLast))
    var ti: UInt32 = 5
    while ti <= 19 {
      if ti != 8 && ti != 12 && ti != 16 {
        Sprite.writeTile(index: ti, rows: emptyRows)
      }
      ti &+= 1
    }

    Sprite.setEnable(true)
    updateSprites()
    loadSounds()

    waitForVsync()
    LCD_ENABLE.store(1)

    var keys = KeyCounter()
    var blink: UInt8 = 0

    while true {
      waitForVsync()

      if state.isPlaying {
        keys.poll()
        blink &+= 1
        LED.store((blink & 0x10) == 0 ? 0x07 : 0x38)

        state.ballX += state.ballDX
        state.ballY += state.ballDY
        if state.ballY <= 0 {
          state.ballY = 0
          state.ballDY = -state.ballDY
          Sound.play(sfxWall)
        }
        if state.ballY >= LCD_H - BALL_S {
          state.ballY = LCD_H - BALL_S
          state.ballDY = -state.ballDY
          Sound.play(sfxWall)
        }

        if keys.up > 0 {
          state.leftY = max(state.leftY - PADDLE_SPEED, 0)
        }
        if keys.down > 0 {
          state.leftY = min(state.leftY + PADDLE_SPEED, LCD_H - PADDLE_H)
        }
        if keys.x > 0 {
          state.rightY = max(state.rightY - PADDLE_SPEED, 0)
        }
        if keys.b > 0 {
          state.rightY = min(state.rightY + PADDLE_SPEED, LCD_H - PADDLE_H)
        }

        if state.ballDX < 0
          && overlaps(
            state.ballX,
            state.ballY,
            BALL_S,
            BALL_S,
            LEFT_X,
            state.leftY,
            PADDLE_W,
            PADDLE_H
          )
        {
          state.ballX = LEFT_X + PADDLE_W
          state.ballDX = BALL_SPEED
          let mid = state.leftY + PADDLE_H / 2
          state.ballDY = state.ballY + BALL_S / 2 < mid ? -BALL_SPEED : BALL_SPEED
          Sound.play(sfxPaddle)
        } else if state.ballDX > 0
          && overlaps(
            state.ballX,
            state.ballY,
            BALL_S,
            BALL_S,
            RIGHT_X,
            state.rightY,
            PADDLE_W,
            PADDLE_H
          )
        {
          state.ballX = RIGHT_X - BALL_S
          state.ballDX = -BALL_SPEED
          let mid = state.rightY + PADDLE_H / 2
          state.ballDY = state.ballY + BALL_S / 2 < mid ? -BALL_SPEED : BALL_SPEED
          Sound.play(sfxPaddle)
        }

        updateSprites()

        if state.ballX <= 0 || state.ballX >= LCD_W - BALL_S {
          Sound.play(sfxGoal)
          state.isPlaying = false
          state.ballX = (LCD_W - 8) / 2
          state.ballY = (LCD_H - 8) / 2
          state.ballDX = -state.ballDX
        }
      } else {
        LED.store(0x15)
        updateSprites()
        waitForKeyPress()
        Sound.play(sfxServe)
        state.isPlaying = true
      }
    }
  }
}
