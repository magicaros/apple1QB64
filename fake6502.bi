'=============================================================================
' Fake6502 for QB64 - NMOS MOS 6502 CPU core                     (declaration)
'-----------------------------------------------------------------------------
' Translated to QB64 from Fake6502 CPU emulator 
' (c)2011-2013 Mike Chambers, released into the public domain.
'
' This QB64 translation is likewise released into the public domain.
' If you use it, please credit Mike Chambers for the original Fake6502.
'
' Usage:
'   '$INCLUDE:'fake6502.bi'    at the top of your program
'   '$INCLUDE:'fake6502.bm'    at the bottom of your program
'
' Your program must provide the bus (this is where your memory map lives):
'   FUNCTION read6502~%% (address AS _UNSIGNED INTEGER)
'   SUB write6502 (address AS _UNSIGNED INTEGER, value AS _UNSIGNED _BYTE)
'
' Public API (see fake6502.bm for details):
'   reset6502            power-on reset, loads PC from $FFFC/$FFFD
'   exec6502 cycles      run for (at least) the given number of clock cycles
'   step6502             execute exactly one instruction
'   irq6502              maskable interrupt request (ignored while I is set)
'   nmi6502              non-maskable interrupt
'
' CPU state is in the shared variable cpu6502 (pc, sp, a, x, y, status,
' clockticks, instructions, jammed).
'=============================================================================

CONST F6502_FLAG_CARRY = &H01
CONST F6502_FLAG_ZERO = &H02
CONST F6502_FLAG_INTERRUPT = &H04
CONST F6502_FLAG_DECIMAL = &H08
CONST F6502_FLAG_BREAK = &H10 ' only exists on the stack copy of P
CONST F6502_FLAG_CONSTANT = &H20 ' always reads as 1
CONST F6502_FLAG_OVERFLOW = &H40
CONST F6502_FLAG_SIGN = &H80

' "Magic" constant used by the unstable opcodes ANE ($8B) and LXA ($AB).
' Real chips vary ($00, $EE, $FF...); $EE matches most C64-era NMOS parts.
CONST F6502_MAGIC = &HEE

TYPE F6502_State
    pc AS _UNSIGNED INTEGER
    sp AS _UNSIGNED _BYTE
    a AS _UNSIGNED _BYTE
    x AS _UNSIGNED _BYTE
    y AS _UNSIGNED _BYTE
    status AS _UNSIGNED _BYTE ' P register; bit 5 always set, B (bit 4) never set
    clockticks AS _UNSIGNED _INTEGER64 ' total clock cycles executed
    clockgoal AS _UNSIGNED _INTEGER64 ' target used by exec6502
    instructions AS _UNSIGNED _INTEGER64 ' total instructions executed
    jammed AS _BYTE ' -1 after a JAM/KIL opcode; only reset6502 recovers
END TYPE

DIM SHARED cpu6502 AS F6502_State

' Internal working variables (not part of the public API)
DIM SHARED f65_ea AS LONG ' effective address of the current instruction
DIM SHARED f65_basehi AS LONG ' high byte of base address before indexing
DIM SHARED f65_crossed AS LONG ' -1 if indexing crossed a page boundary
DIM SHARED f65_cyc AS LONG ' cycles spent by the current instruction
