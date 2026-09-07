// Linker-defined section boundary symbols (see linker/memmap.ld).
// Their addresses — not values — represent the section boundaries.
// Equivalent to `extern char __data_org;` in C, where `&__data_org`
// gives the address.
@_extern(c, "_end") nonisolated(unsafe) var _end: UInt8

/// Returns the address of a linker-defined symbol.
///
/// Equivalent to `(uintptr_t)&symbol` in C.
@inline(__always)
func linkerSymbolAddress(_ symbol: inout UInt8) -> UInt {
  withUnsafePointer(to: &symbol) { UInt(bitPattern: $0) }
}
