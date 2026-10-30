# apple1QB64
a very simple apple1 emulator based of Mike Chambers Fake6502 for the cpu but ported to QB64 Phoenix edition, as yes in basic instead of c, QB64 transpile the basic code into c++ anyways

behaviour follows the original 6502 (MOS Technology 6502/6510) not 65C02. At startup it look for a wozmon.bin or wozmon.txt for either a bin dump or hexdump of the apple1 woz monitor, not provided here, bring your own rom dump it read from commandline for optional text hexdump file to pass as keyboard input to woz monitor upon starting, provided a simple hello world (hello.txt)

# Memory map

-   $0000-$CFFF  RAM
-   $D000-$DFFF  I/O space (only the PIA below is decoded)
-     $D010  KBD    PIA port A data   - keyboard (bit 7 always set)
-     $D011  KBDCR  PIA control reg A - bit 7 = 1 when a key is waiting
-     $D012  DSP    PIA port B data   - write a character; bit 7 = busy
-     $D013  DSPCR  PIA control reg B
-   $E000-$FEFF  RAM (where Integer BASIC would go)
-   $FF00-$FFFF  ROM - the Woz Monitor (wozmon.bin), write-protected
