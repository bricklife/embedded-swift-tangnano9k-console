@_extern(c, "_end") nonisolated(unsafe) var _end: UInt8

@inline(__always)
func linkerSymbolAddress(_ symbol: inout UInt8) -> UInt {
  withUnsafePointer(to: &symbol) { UInt(bitPattern: $0) }
}
