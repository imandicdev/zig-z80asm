; sjasmplus local labels: .name belongs to the last ordinary label, EQU or =
; before it, and outer.name reaches it from anywhere.

        ORG 8000h
.first: NOP                     ; before any label
outer:  NOP
.loop:  DJNZ .loop
.next   NOP                     ; in column 0, without a colon
inner:
.loop:  JR .loop                ; another scope, so no duplicate
        DW outer.loop, inner.loop, .loop, outer.next

value   EQU 5                   ; EQU starts a new scope as well
.loop:  DB value
three   = 3                     ; and so does =
.loop:  DB three
        DW value.loop, three.loop, .loop

        IF 0
.loop:  NOP                     ; skipped, so no duplicate
        ENDIF
