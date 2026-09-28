; The program of the format tests (test/formats_test.zig): code, a message,
; and enough data that a TRS-80 /CMD file needs two load records. It has no
; END, so compare/gen_formats.py can include it and save it with sjasmplus;
; the entry is then the origin.

        ORG 8000h
start:  LD HL,message
        LD A,(HL)
        RET
message:
        DB "z80asm formats"
        DS 300, 0AAh
program_end:
