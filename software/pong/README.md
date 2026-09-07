# Pong (Embedded Swift / Tang Nano 9K)

Pong, linked at `0x2000` and loaded as SD `PROG.BIN`.

## Controls

| Side | Action |
|---|---|
| Left paddle | `Key.up` / `Key.down` |
| Right paddle | `Key.x` (up) / `Key.b` (down) |
| Serve | Any key (at start and after a goal) |

No score display. When the ball leaves left or right, that is a goal and the game waits for a re-serve.

Sound uses the same PWM score player as `sfx` (`0x4000_3000`, pin 30): paddle hit / wall bounce / goal / serve. Requires a bitstream with PWM audio.

Dropped frames are counted with `LCD_FRAME` (`0x4000_1008`). Extra increments beyond 1 during `waitForVsync` are printed on UART.

## Display

- Paddles: 32×32 sprites (drawn as an 8 px vertical bar on the left of the sprite)
- Ball: 8×8 sprite
- Background: Swift-logo orange fill plus a 96×96 bird in the center (`Logo.swift`)

Three sprites (requires a bitstream with N=4 / M=4).

## Build

Open-source Swift 6.3.2 (RISC-V). The Swift bundled with Xcode cannot be used.

```bash
make -C software/pong
cp software/pong/pong.bin /Volumes/<SD>/PROG.BIN
```
