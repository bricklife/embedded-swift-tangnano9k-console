struct KeyCounter {
  var currentKeys = Key()

  var right: UInt = 0
  var left: UInt = 0
  var up: UInt = 0
  var down: UInt = 0
  var select: UInt = 0
  var start: UInt = 0
  var a: UInt = 0
  var b: UInt = 0
  var x: UInt = 0
  var y: UInt = 0

  mutating func poll() {
    currentKeys = Key.poll()
    right = currentKeys.contains(.right) ? right &+ 1 : 0
    left = currentKeys.contains(.left) ? left &+ 1 : 0
    up = currentKeys.contains(.up) ? up &+ 1 : 0
    down = currentKeys.contains(.down) ? down &+ 1 : 0
    select = currentKeys.contains(.select) ? select &+ 1 : 0
    start = currentKeys.contains(.start) ? start &+ 1 : 0
    a = currentKeys.contains(.a) ? a &+ 1 : 0
    b = currentKeys.contains(.b) ? b &+ 1 : 0
    x = currentKeys.contains(.x) ? x &+ 1 : 0
    y = currentKeys.contains(.y) ? y &+ 1 : 0
  }
}
