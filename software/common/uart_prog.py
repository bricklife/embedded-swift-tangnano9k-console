#!/usr/bin/env python3
"""Send a raw RISC-V binary to the soft SD bootloader over UART.

Used when SD boot fails (no card / no PROG.BIN). The bootloader prints
ERR xx then URX., then accepts:

  - 4-byte little-endian length
  - that many payload bytes (clamped to 24 KiB at 0x2000)

Usage:
  python3 uart_prog.py /dev/cu.usbserial-101 ../pong/pong.bin
  python3 uart_prog.py /dev/cu.usbserial-101 ../pong/pong.bin -m
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import termios
import time


def open_serial(path: str, baud: int = 115200):
    try:
        import serial  # type: ignore

        return serial.Serial(path, baud, timeout=0.05)
    except ImportError:
        pass

    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[3] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    speed = getattr(termios, f"B{baud}", termios.B115200)
    attrs[4] = speed
    attrs[5] = speed
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)

    class FdSerial:
        def __init__(self, fd: int):
            self.fd = fd

        def read(self, n: int = 1) -> bytes:
            try:
                return os.read(self.fd, n)
            except BlockingIOError:
                return b""

        def write(self, data: bytes) -> int:
            return os.write(self.fd, data)

        def close(self) -> None:
            os.close(self.fd)

    return FdSerial(fd)


def monitor_forever(ser) -> None:
    """Print UART RX until Ctrl-C."""
    print("\n--- monitor (Ctrl-C to stop) ---", flush=True)
    try:
        while True:
            chunk = ser.read(256)
            if chunk:
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
            else:
                time.sleep(0.02)
    except KeyboardInterrupt:
        print("\n--- monitor stopped ---", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("port", help="serial device, e.g. /dev/cu.usbserial-101")
    ap.add_argument("binary", help="raw program image linked at 0x2000 (.bin)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument(
        "--wait-urx",
        type=float,
        default=30.0,
        help="seconds to wait for URX. banner (default 30)",
    )
    ap.add_argument(
        "--no-wait",
        action="store_true",
        help="send immediately without waiting for URX.",
    )
    ap.add_argument(
        "--max-bytes",
        type=int,
        default=24 * 1024,
        help="max payload (soft boot app region, default 24 KiB)",
    )
    ap.add_argument(
        "-m",
        "--monitor",
        action="store_true",
        help="after load (OK or timeout), keep printing UART until Ctrl-C",
    )
    args = ap.parse_args()

    data = open(args.binary, "rb").read()
    if len(data) > args.max_bytes:
        print(
            f"warning: truncating {len(data)} -> {args.max_bytes} bytes",
            file=sys.stderr,
        )
        data = data[: args.max_bytes]

    ser = open_serial(args.port, args.baud)
    exit_code = 1
    try:
        buf = b""
        if not args.no_wait:
            print(f"waiting for URX. on {args.port} ...", flush=True)
            t0 = time.time()
            while time.time() - t0 < args.wait_urx:
                chunk = ser.read(256)
                if chunk:
                    buf += chunk
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    if b"URX." in buf:
                        break
                else:
                    time.sleep(0.02)
            else:
                print("\ntimeout waiting for URX.", file=sys.stderr)
                if args.monitor:
                    monitor_forever(ser)
                return 1

        header = struct.pack("<I", len(data))
        print(f"\nsending {len(data)} bytes (+4 length) ...", flush=True)
        ser.write(header)
        # Pace for soft-boot CPU polling (uart_mini RX FIFO is small).
        # ~115200 → 64 bytes ≈ 5.5 ms; sleep a bit more between chunks.
        off = 0
        chunk = 64
        while off < len(data):
            n = min(chunk, len(data) - off)
            ser.write(data[off : off + n])
            off += n
            drain = ser.read(256)
            if drain:
                buf += drain
                sys.stdout.buffer.write(drain)
                sys.stdout.buffer.flush()
            time.sleep(0.008)

        print("sent; waiting for PRG OK / app ...", flush=True)
        t0 = time.time()
        while time.time() - t0 < 20.0:
            chunk = ser.read(256)
            if chunk:
                buf += chunk
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                if b"PRG OK" in buf or b"Hazard3" in buf or b"mode: game" in buf:
                    print("\nOK", flush=True)
                    exit_code = 0
                    break
            else:
                time.sleep(0.02)
        else:
            print("\ntimeout waiting for app boot", file=sys.stderr)
            exit_code = 1

        if args.monitor:
            monitor_forever(ser)

        return exit_code
    finally:
        ser.close()


if __name__ == "__main__":
    sys.exit(main())
