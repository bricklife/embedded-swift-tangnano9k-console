// Runtime stubs for Embedded Swift on bare metal (-nostdlib).

// MARK: - Heap (bump)

nonisolated(unsafe) var heapPointer: UInt = 0

@c
func posix_memalign(
  _ memptr: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
  _ alignment: UInt,
  _ size: UInt
) -> Int32 {
  if heapPointer == 0 {
    heapPointer = linkerSymbolAddress(&_end)
  }
  var address = heapPointer
  address = (address &+ alignment &- 1) & ~(alignment &- 1)
  memptr.pointee = UnsafeMutableRawPointer(bitPattern: address)
  heapPointer = address &+ size
  return 0
}

@c
func free(_ ptr: UnsafeMutableRawPointer?) {
  _ = ptr
}

// MARK: - libc primitives

@c
func memset(
  _ s: UnsafeMutableRawPointer?,
  _ c: Int32,
  _ n: Int
) -> UnsafeMutableRawPointer? {
  guard let s, n > 0 else { return s }
  let byte = UInt8(truncatingIfNeeded: c)
  var p = s.assumingMemoryBound(to: UInt8.self)
  var remaining = n
  while remaining > 0 {
    p.pointee = byte
    p = p.advanced(by: 1)
    remaining &-= 1
  }
  return s
}

// MARK: - putchar for Embedded Swift print (optional)

@c
func putchar(_ c: Int32) -> Int32 {
  let byte = UInt8(truncatingIfNeeded: c)
  if byte == UInt8(ascii: "\n") {
    UART.putc(UInt8(ascii: "\r"))
  }
  UART.putc(byte)
  return c
}
