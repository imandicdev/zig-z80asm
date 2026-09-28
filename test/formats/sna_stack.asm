; A program over the stack that sjasmplus sets up under RAMTOP (0x5D58 to
; 0x5D5B), so an sna file cannot put the start there: sjasmplus puts it at
; 0x4000, on the screen (test/formats_test.zig). No END, as in program.asm.

        ORG 5D50h
start:  DI
        DS 15, 0AAh
