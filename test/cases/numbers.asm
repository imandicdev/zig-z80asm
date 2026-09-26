; Number formats and character literals
    ORG 0x8000
    LD A,$FF
    LD A,0FFh
    LD A,0FFH
    LD A,0xFF
    LD A,%1010
    LD A,1010b
    LD A,0b1010
    LD A,0B8H
    LD A,'A'
    LD A,"Z"
    LD A,-1
    LD A,-128
    LD HL,65535
    LD HL,-1
    LD BC,1234h
    DB 0,255,-1,'x'
    DW 0,65535,-1
; '%' right after a mnemonic is still a binary prefix
    DB %00001111
    AND %0001
    DEFB %10000000,%1
