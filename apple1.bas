'=============================================================================
' apple1.bas - an Apple-1 style mini system around the Fake6502 QB64 core
'-----------------------------------------------------------------------------
' Public domain. Enough hardware to run the Woz Monitor and tinker in 6502.
'
' Memory map
'   $0000-$CFFF  RAM
'   $D000-$DFFF  I/O space (only the PIA below is decoded)
'     $D010  KBD    PIA port A data   - keyboard (bit 7 always set)
'     $D011  KBDCR  PIA control reg A - bit 7 = 1 when a key is waiting
'     $D012  DSP    PIA port B data   - write a character; bit 7 = busy
'     $D013  DSPCR  PIA control reg B
'   $E000-$FEFF  RAM (where Integer BASIC would go)
'   $FF00-$FFFF  ROM - the Woz Monitor (wozmon.bin), write-protected
'
' The PIA is a 6821 as on the Apple-1: one chip, port A for the keyboard and
' port B for the display. Bit 2 of each control register selects the data
' register (1) or the data-direction register (0), as on the real part;
' the Woz Monitor relies on that during its initialisation.
'
' Put the 256-byte Woz Monitor ROM next to this program as wozmon.bin, or as
' wozmon.txt in Woz Monitor hex-dump form ("FF00: D8 58 A0 7F ...").
'
' Keys
'   F1  RESET (like the Apple-1 reset switch; memory is kept)
'   F2  CLEAR SCREEN
'   F3  or Ctrl+V   paste the clipboard as typed keys
'   Backspace types "_" (the Woz Monitor's rub-out), Esc cancels a line
'
' Command line (files are relative to the folder you start from)
'   apple1 prog.txt          types the file in, e.g. a Woz Monitor hex dump
'   apple1 prog.bin@0300     loads a binary directly into memory at $0300
'   (any number of each, processed in order)
'=============================================================================

' Set to 1 to build a console-only version that reads keystrokes from the
' files on the command line and prints the final screen (used for testing).
$LET HEADLESS = 0

$IF HEADLESS = 1 THEN
    $CONSOLE:ONLY
$END IF
OPTION _EXPLICIT

'$INCLUDE:'fake6502.bi'

CONST CPU_HZ = 1023000 ' Apple-1 clock: 1.023 MHz
CONST FPS = 60
CONST DISPLAY_CPS = 0 ' 0 = instant output; 60 = authentic Apple-1 speed
CONST SCALE = 3 ' window size = 320x192 pixels times SCALE
CONST COLS = 40
CONST ROWS = 24

' Memory
DIM SHARED mem(0 TO 65535) AS _UNSIGNED _BYTE
DIM SHARED romloaded AS LONG

' 6821 PIA
DIM SHARED pia_cra AS LONG, pia_crb AS LONG
DIM SHARED pia_ddra AS LONG, pia_ddrb AS LONG
DIM SHARED pia_ora AS LONG, pia_orb AS LONG
DIM SHARED kbd_latch AS LONG
DIM SHARED kbd_queue AS STRING
DIM SHARED disp_busy_until AS _UNSIGNED _INTEGER64

' Terminal: 40 x 24 characters, like the Apple-1 video section
DIM SHARED scr(0 TO COLS - 1, 0 TO ROWS - 1) AS _UNSIGNED _BYTE
DIM SHARED curx AS LONG, cury AS LONG

DIM SHARED frame AS LONG
DIM SHARED quit AS LONG
DIM SHARED idle_frames AS LONG ' headless build only
DIM SHARED textimg AS LONG ' windowed build only

'-----------------------------------------------------------------------------
' Main program
'-----------------------------------------------------------------------------

InitPlatform
ClearScreen
LoadRom
ProcessCommandLine

IF romloaded THEN
    ResetMachine
    DO
        exec6502 CPU_HZ \ FPS
        PlatformFrame
        frame = frame + 1
    LOOP UNTIL quit
ELSE
    TermString "WOZMON ROM NOT FOUND." + CHR$(13)
    TermString "PUT WOZMON.BIN (256 BYTES) OR" + CHR$(13)
    TermString "WOZMON.TXT (HEX DUMP) NEXT TO" + CHR$(13)
    TermString "THIS PROGRAM AND START AGAIN." + CHR$(13)
    DO
        PlatformFrame
    LOOP UNTIL quit
END IF
SYSTEM

'-----------------------------------------------------------------------------
' Machine control
'-----------------------------------------------------------------------------

' The Apple-1 reset switch resets the CPU and the PIA, but not memory.
SUB ResetMachine
    pia_cra = 0: pia_crb = 0
    pia_ddra = 0: pia_ddrb = 0
    pia_ora = 0: pia_orb = 0
    disp_busy_until = 0
    reset6502
END SUB

SUB LoadRom
    DIM buf AS STRING, i AS LONG
    IF _FILEEXISTS("wozmon.bin") THEN
        OPEN "wozmon.bin" FOR BINARY AS #1
        IF LOF(1) = 256 THEN
            buf = SPACE$(256)
            GET #1, 1, buf
            FOR i = 0 TO 255
                mem(&HFF00& + i) = ASC(buf, i + 1)
            NEXT
            romloaded = -1
        END IF
        CLOSE #1
    ELSEIF _FILEEXISTS("wozmon.txt") THEN
        romloaded = LoadHexDump("wozmon.txt") >= 256
    END IF
END SUB

' Reads "ADDR: BB BB BB ..." lines (Woz Monitor output format) into memory,
' bypassing ROM protection. Returns the number of bytes loaded.
FUNCTION LoadHexDump& (filename AS STRING)
    DIM ln AS STRING, p AS LONG, addr AS LONG, n AS LONG, tok AS STRING
    OPEN filename FOR INPUT AS #1
    DO UNTIL EOF(1)
        LINE INPUT #1, ln
        p = INSTR(ln, ":")
        IF p > 0 THEN
            addr = VAL("&H" + _TRIM$(LEFT$(ln, p - 1)) + "&")
            ln = _TRIM$(MID$(ln, p + 1)) + " "
            DO WHILE LEN(ln) > 1
                p = INSTR(ln, " ")
                tok = LEFT$(ln, p - 1)
                ln = LTRIM$(MID$(ln, p + 1)) + ""
                IF LEN(tok) THEN
                    mem(addr AND &HFFFF&) = VAL("&H" + tok)
                    addr = addr + 1
                    n = n + 1
                END IF
            LOOP
        END IF
    LOOP
    CLOSE #1
    LoadHexDump& = n
END FUNCTION

' Text files are queued as keystrokes; "file.bin@hhhh" is loaded at $hhhh.
SUB ProcessCommandLine
    DIM i AS LONG, arg AS STRING, p AS LONG, addr AS LONG, buf AS STRING, j AS LONG
    FOR i = 1 TO _COMMANDCOUNT
        arg = COMMAND$(i)
        p = _INSTRREV(arg, "@")
        IF p > 0 THEN
            addr = VAL("&H" + MID$(arg, p + 1) + "&")
            arg = FullPath(LEFT$(arg, p - 1))
            IF _FILEEXISTS(arg) THEN
                OPEN arg FOR BINARY AS #1
                buf = SPACE$(LOF(1))
                GET #1, 1, buf
                CLOSE #1
                FOR j = 1 TO LEN(buf)
                    mem((addr + j - 1) AND &HFFFF&) = ASC(buf, j)
                NEXT
            END IF
        ELSE
            arg = FullPath(arg)
            IF _FILEEXISTS(arg) THEN
                OPEN arg FOR BINARY AS #1
                buf = SPACE$(LOF(1))
                GET #1, 1, buf
                CLOSE #1
                TypeText buf
            END IF
        END IF
    NEXT
END SUB

FUNCTION FullPath$ (f AS STRING)
    IF LEFT$(f, 1) = "/" OR LEFT$(f, 1) = "\" OR MID$(f, 2, 1) = ":" THEN
        FullPath$ = f
    ELSE
        FullPath$ = _STARTDIR$ + "/" + f
    END IF
END FUNCTION

' Queue text as Apple-1 keystrokes: upper case, line ends become CR
SUB TypeText (t AS STRING)
    DIM i AS LONG, c AS LONG, prev AS LONG
    FOR i = 1 TO LEN(t)
        c = ASC(t, i)
        SELECT CASE c
            CASE 13: kbd_queue = kbd_queue + CHR$(13)
            CASE 10: IF prev <> 13 THEN kbd_queue = kbd_queue + CHR$(13) ' LF or CRLF
            CASE 9: kbd_queue = kbd_queue + " "
            CASE 97 TO 122: kbd_queue = kbd_queue + CHR$(c - 32)
            CASE 32 TO 126: kbd_queue = kbd_queue + CHR$(c)
        END SELECT
        prev = c
    NEXT
END SUB

'-----------------------------------------------------------------------------
' The bus
'-----------------------------------------------------------------------------

FUNCTION read6502~%% (address AS _UNSIGNED INTEGER)
    IF address >= &HD000& AND address <= &HDFFF& THEN
        read6502~%% = IORead(address)
    ELSE
        read6502~%% = mem(address)
    END IF
END FUNCTION

SUB write6502 (address AS _UNSIGNED INTEGER, value AS _UNSIGNED _BYTE)
    IF address < &HD000& THEN
        mem(address) = value
    ELSEIF address <= &HDFFF& THEN
        IOWrite address, value
    ELSEIF address < &HFF00& THEN
        mem(address) = value
    END IF ' $FF00-$FFFF is ROM
END SUB

'-----------------------------------------------------------------------------
' 6821 PIA
'-----------------------------------------------------------------------------

' If no key is waiting, take the next one from the queue and raise the
' CA1 flag (bit 7 of KBDCR), as a keypress on the Apple-1 keyboard does.
SUB KbdFeed
    IF (pia_cra AND &H80) = 0 AND LEN(kbd_queue) > 0 THEN
        kbd_latch = ASC(kbd_queue, 1)
        kbd_queue = MID$(kbd_queue, 2)
        pia_cra = pia_cra OR &H80
    END IF
END SUB

FUNCTION IORead& (address AS LONG)
    DIM v AS LONG
    SELECT CASE address
        CASE &HD010& ' KBD
            IF pia_cra AND 4 THEN
                ' input pins: keyboard data, PA7 tied high on the Apple-1
                v = (pia_ora AND pia_ddra) OR ((kbd_latch OR &H80) AND (NOT pia_ddra))
                pia_cra = pia_cra AND &H7F ' reading port A clears the flag
            ELSE
                v = pia_ddra
            END IF
        CASE &HD011& ' KBDCR
            KbdFeed
            v = pia_cra
        CASE &HD012& ' DSP
            IF pia_crb AND 4 THEN
                v = pia_orb AND pia_ddrb
                ' PB7 is an input: high while the terminal is busy
                IF cpu6502.clockticks < disp_busy_until THEN v = v OR (&H80 AND (NOT pia_ddrb))
            ELSE
                v = pia_ddrb
            END IF
        CASE &HD013& ' DSPCR
            v = pia_crb
        CASE ELSE
            v = 0 ' unmapped I/O
    END SELECT
    IORead& = v AND &HFF
END FUNCTION

SUB IOWrite (address AS LONG, value AS LONG)
    SELECT CASE address
        CASE &HD010&
            IF pia_cra AND 4 THEN pia_ora = value ELSE pia_ddra = value
        CASE &HD011&
            pia_cra = (pia_cra AND &HC0) OR (value AND &H3F) ' flags are read-only
        CASE &HD012&
            IF pia_crb AND 4 THEN
                pia_orb = value
                TermPut value
                IF DISPLAY_CPS > 0 THEN disp_busy_until = cpu6502.clockticks + CPU_HZ \ DISPLAY_CPS
            ELSE
                pia_ddrb = value
            END IF
        CASE &HD013&
            pia_crb = (pia_crb AND &HC0) OR (value AND &H3F)
    END SELECT
END SUB

'-----------------------------------------------------------------------------
' Terminal (Apple-1 style: upper case only, CR is the only control code)
'-----------------------------------------------------------------------------

SUB ClearScreen
    DIM x AS LONG, y AS LONG
    FOR y = 0 TO ROWS - 1
        FOR x = 0 TO COLS - 1
            scr(x, y) = 32
        NEXT
    NEXT
    curx = 0: cury = 0
END SUB

SUB TermNewLine
    DIM x AS LONG, y AS LONG
    curx = 0
    cury = cury + 1
    IF cury >= ROWS THEN
        FOR y = 1 TO ROWS - 1
            FOR x = 0 TO COLS - 1
                scr(x, y - 1) = scr(x, y)
            NEXT
        NEXT
        FOR x = 0 TO COLS - 1
            scr(x, ROWS - 1) = 32
        NEXT
        cury = ROWS - 1
    END IF
END SUB

SUB TermPut (value AS LONG)
    DIM c AS LONG
    c = value AND &H7F
    IF c = 13 THEN
        TermNewLine
    ELSEIF c >= 32 THEN
        IF c >= 96 THEN c = c - 32 ' no lower case on the Apple-1
        scr(curx, cury) = c
        curx = curx + 1
        IF curx >= COLS THEN TermNewLine
    END IF
END SUB

SUB TermString (s AS STRING)
    DIM i AS LONG
    FOR i = 1 TO LEN(s)
        TermPut ASC(s, i)
    NEXT
END SUB

FUNCTION ScreenRow$ (y AS LONG)
    DIM s AS STRING, x AS LONG
    s = SPACE$(COLS)
    FOR x = 0 TO COLS - 1
        ASC(s, x + 1) = scr(x, y)
    NEXT
    ScreenRow$ = s
END FUNCTION

'-----------------------------------------------------------------------------
' Platform: window, rendering and keyboard
'-----------------------------------------------------------------------------

$IF HEADLESS = 1 THEN

    ' Headless: runs until all queued keys are consumed (plus one second),
    ' then prints the screen.
    SUB InitPlatform
    END SUB

    SUB PlatformFrame
        DIM y AS LONG
        IF LEN(kbd_queue) = 0 THEN idle_frames = idle_frames + 1
        IF idle_frames > FPS OR frame > FPS * 600 THEN
            FOR y = 0 TO ROWS - 1
                PRINT RTRIM$(ScreenRow$(y))
            NEXT
            PRINT "-- PC=$"; HEX$(cpu6502.pc); " cycles:"; cpu6502.clockticks
            quit = -1
        END IF
    END SUB

$ELSE

    SUB InitPlatform
        SCREEN _NEWIMAGE(COLS * 8 * SCALE, ROWS * 8 * SCALE, 32)
        textimg = _NEWIMAGE(COLS * 8, ROWS * 8, 32)
        _DEST textimg
        _FONT 8
        _DEST 0
        _TITLE "Apple-1 (Fake6502)  F1 Reset  F2 Clear  F3 Paste"
    END SUB

    SUB PlatformFrame
        DIM y AS LONG, k AS STRING, c AS LONG

        ' keyboard
        DO
            k = INKEY$
            IF k = "" THEN EXIT DO
            IF LEN(k) = 2 THEN
                SELECT CASE ASC(k, 2)
                    CASE 59: ResetMachine ' F1
                    CASE 60: ClearScreen ' F2
                    CASE 61: TypeText _CLIPBOARD$ ' F3
                END SELECT
            ELSE
                c = ASC(k)
                SELECT CASE c
                    CASE 8: kbd_queue = kbd_queue + "_" ' rub-out
                    CASE 13, 27: kbd_queue = kbd_queue + CHR$(c)
                    CASE 22: TypeText _CLIPBOARD$ ' Ctrl+V
                    CASE 97 TO 122: kbd_queue = kbd_queue + CHR$(c - 32)
                    CASE 32 TO 126: kbd_queue = kbd_queue + CHR$(c)
                END SELECT
            END IF
        LOOP

        ' screen: green phosphor, blinking "@" cursor as on the Apple-1
        _DEST textimg
        COLOR _RGB32(80, 255, 110), _RGB32(0, 0, 0)
        CLS
        FOR y = 0 TO ROWS - 1
            _PRINTSTRING (0, y * 8), ScreenRow$(y)
        NEXT
        IF (frame \ 16) MOD 2 = 0 THEN _PRINTSTRING (curx * 8, cury * 8), "@"
        _DEST 0
        _PUTIMAGE (0, 0)-(_WIDTH(0) - 1, _HEIGHT(0) - 1), textimg, 0
        _DISPLAY
        _LIMIT FPS
        IF _EXIT THEN quit = -1
    END SUB

$END IF

'$INCLUDE:'fake6502.bm'
