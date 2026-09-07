enum Color: UInt16, CaseIterable {
  case black = 0x0000
  case gray = 0x8410
  case white = 0xffff
  case red = 0xf800
  case green = 0x07e0
  case blue = 0x001f
  case yellow = 0xffe0
  // Swift logo fill (logo.png / 0xEA87)
  case orange = 0xea87
  // Warm set for sprites on orange: sand / cocoa / umber
  case cream = 0xc618
  case cocoa = 0x69c6
  case umber = 0x30a2
}
