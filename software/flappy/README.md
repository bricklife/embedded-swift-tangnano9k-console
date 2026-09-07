# Flappy (Embedded Swift / Tang Nano 9K)

A Flappy Bird-style game. Flap a 16×16 Swift-logo bird under gravity and fly through gaps in 32×32-sprite pillars.

Hitting a pillar or the floor stops the game; any key restarts. At most two pillars are on screen (16 sprites: 1 player + up to 6×2 for pillars).

Sound uses the same PWM score player as `sfx` (`0x4000_3000`, pin 30): flap / pass / crash / start.

## Controls

| Action | Key |
|---|---|
| Flap | `Key.up` or `Key.a` (on press) |
| Start / restart | Any key (press and release) |

The gap is empty (no sprites). A scanline has at most two pillar sprites plus the player, which fits `MAX_PER_LINE=4`.

Requires a bitstream with N=16 / M=4 and PWM audio.

## Build

```bash
make -C software/flappy
cp software/flappy/flappy.bin /Volumes/<SD>/PROG.BIN
```
