# Dodge (Embedded Swift / Tang Nano 9K)

Same link layout as `pong` (`0x2000`, SD `PROG.BIN`).

Dodge falling obstacles with a 32×32 player. On hit the game stops and waits for a key to restart.

## Controls

| Action | Key |
|---|---|
| Move left | `Key.left` |
| Move right | `Key.right` |
| Start / restart | Any key (press and release) |

No score display.

## Sprites

| OAM | Contents | Size | Tiles |
|---|---|---|---|
| 0 | Player | 32×32 | 0..15 |
| 1..7 | Obstacles (same art) | 16×16 | 16..19 |

Obstacles are staggered in Y so they rarely hit the 4-sprites-per-line limit.

Requires a bitstream with N=16 / M=4 and 32×32 sprites.

## Build

```bash
make -C software/dodge
cp software/dodge/dodge.bin /Volumes/<SD>/PROG.BIN
```
