@main
struct GameMain {
  static let scoreA: UInt32 = 0  // coin
  static let scoreB: UInt32 = 1  // bump
  static let scoreX: UInt32 = 2  // jump
  static let scoreY: UInt32 = 3  // melody

  static func loadCoin() {
    Sound.select(scoreA)
    Sound.clear()
    Sound.push(pitch: .c5, milliseconds: 70)
    Sound.push(pitch: .e5, milliseconds: 70)
    Sound.push(pitch: .g5, milliseconds: 70)
    Sound.push(pitch: .c6, milliseconds: 140)
  }

  static func loadBump() {
    Sound.select(scoreB)
    Sound.clear()
    Sound.push(pitch: .g4, milliseconds: 50)
    Sound.push(pitch: .ds4, milliseconds: 50)
    Sound.push(pitch: .c4, milliseconds: 90)
  }

  static func loadJump() {
    Sound.select(scoreX)
    Sound.clear()
    Sound.push(pitch: .c4, milliseconds: 55)
    Sound.push(pitch: .e4, milliseconds: 55)
    Sound.push(pitch: .g4, milliseconds: 55)
    Sound.push(pitch: .c5, milliseconds: 80)
    Sound.push(pitch: .e5, milliseconds: 110)
  }

  // Public-domain phrase (Ode to Joy), ~6 s.
  static func loadMelody() {
    let qq: UInt32 = 100
    let q: UInt32 = 200
    let hq: UInt32 = 300
    let h: UInt32 = 400
    Sound.select(scoreY)
    Sound.clear()
    Sound.push(pitch: .e4, milliseconds: q)
    Sound.push(pitch: .e4, milliseconds: q)
    Sound.push(pitch: .f4, milliseconds: q)
    Sound.push(pitch: .g4, milliseconds: q)
    Sound.push(pitch: .g4, milliseconds: q)
    Sound.push(pitch: .f4, milliseconds: q)
    Sound.push(pitch: .e4, milliseconds: q)
    Sound.push(pitch: .d4, milliseconds: q)
    Sound.push(pitch: .c4, milliseconds: q)
    Sound.push(pitch: .c4, milliseconds: q)
    Sound.push(pitch: .d4, milliseconds: q)
    Sound.push(pitch: .e4, milliseconds: q)
    Sound.push(pitch: .e4, milliseconds: hq)
    Sound.push(pitch: .d4, milliseconds: qq)
    Sound.push(pitch: .d4, milliseconds: hq)
    Sound.push(pitch: .rest, milliseconds: qq)
    Sound.push(pitch: .e4, milliseconds: q)
    Sound.push(pitch: .e4, milliseconds: q)
    Sound.push(pitch: .f4, milliseconds: q)
    Sound.push(pitch: .g4, milliseconds: q)
    Sound.push(pitch: .g4, milliseconds: q)
    Sound.push(pitch: .f4, milliseconds: q)
    Sound.push(pitch: .e4, milliseconds: q)
    Sound.push(pitch: .d4, milliseconds: q)
    Sound.push(pitch: .c4, milliseconds: q)
    Sound.push(pitch: .c4, milliseconds: q)
    Sound.push(pitch: .d4, milliseconds: q)
    Sound.push(pitch: .e4, milliseconds: q)
    Sound.push(pitch: .d4, milliseconds: hq)
    Sound.push(pitch: .c4, milliseconds: qq)
    Sound.push(pitch: .c4, milliseconds: h)
  }

  static func main() {
    loadCoin()
    loadBump()
    loadJump()
    loadMelody()

    var keys = KeyCounter()
    while true {
      keys.poll()
      if keys.a == 1 { Sound.play(scoreA) }
      if keys.b == 1 { Sound.play(scoreB) }
      if keys.x == 1 { Sound.play(scoreX) }
      if keys.y == 1 { Sound.play(scoreY) }
      if keys.start == 1 { Sound.stop() }
    }
  }
}
