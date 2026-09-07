enum Color: UInt16, CaseIterable {
  case black = 0x0000
  case gray = 0x8410
  case dim = 0x4208
  case white = 0xffff
  case red = 0xf800
  case yellow = 0xffe0
  case hull = 0x3d7f
  case hullDark = 0x1a34
  /// Official Swift orange #F05138
  case swift = 0xea87
  case swiftDk = 0xc1e5
  case orange = 0xfd20
  case metal = 0xc618
  case ring = 0xfbe0
  case ringDk = 0xc2c0
  case ringHi = 0xfff3
  case pipe = 0x25c8
  case pipeDk = 0x1324
  case pipeHi = 0x3eed
  case grass = 0x1d80
  case dirt = 0x8200
  /// #4EC0CA → RGB565
  case sky = 0x4df9
}
