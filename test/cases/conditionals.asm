; IF, IFDEF, IFNDEF, ELSEIF, ELSE and ENDIF. Each DB value says which branch
; was assembled.

one     EQU 1

        IF one
        DB 1
        ELSE
        DB 2
        ENDIF

        IF one == 2
        DB 3
        ELSEIF one == 1
        DB 4
        ELSEIF one == 1
        DB 5
        ELSE
        DB 6
        ENDIF

        IF 0
        DB 7
        ELSEIF 0
        DB 8
        ELSE
        DB 9
        ENDIF

; Nested, and nested inside a skipped block.
        IF 1
          IF 0
          DB 10
          ELSE
          DB 11
          ENDIF
        ENDIF
        IF 0
          IF 1
          DB 12
          ELSE
          DB 13
          ENDIF
        ELSEIF 1
          DB 14
        ENDIF

; IFDEF and IFNDEF of a name that is nothing. sjasmplus tests DEFINE names
; with them and z80asm tests symbols (see test/assembler_test.zig), so only
; this case is the same in both.
        IFDEF nothing
        DB 15
        ELSE
        DB 16
        ENDIF
        IFNDEF nothing
        DB 17
        ENDIF

; A forward reference in IF takes the value from the previous pass.
        IF later == 5           ; fwdref-ok (sjasmplus warns, z80asm does not)
        DB 19
        ENDIF

; A skipped block may hold anything.
        IF 0
        this is not Z80 @ all
        ENDIF

later   EQU 5

; A label in a skipped block is not defined, so it is no duplicate.
twice:  DB 20
        IF 0
twice:  DB 21
        ENDIF
