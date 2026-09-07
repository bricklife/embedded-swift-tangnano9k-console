# sfx (ABXY sound effects / Embedded Swift)

No display or UART. A/B/X/Y play the hardware score player (`0x4000_3000`, pin 30).

| Button | Score | Contents |
|---|---|---|
| A | 0 | Coin (short rising) |
| B | 1 | Hit (short falling) |
| X | 2 | Jump (short arpeggio) |
| Y | 3 | Longer melody (opening of Ode to Joy) |

Requires a bitstream with PWM audio.

```bash
make -C software/sfx
cp software/sfx/sfx.bin /Volumes/<SD>/PROG.BIN
```
