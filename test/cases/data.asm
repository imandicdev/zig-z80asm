; Data directives
    ORG 0xC000
    DB 1
    DB 1,2,3
    DB "abc"
    DB "abc",0
    DB 'x','y'
    DB "a;b",';'
    DEFB 7
    DEFM "msg"
    DW 0x1234
    DW 1,2,3
    DEFW 0xBEEF
    DS 3
    DS 2,0xAA
    DEFS 1,'-'
    DB $-0xC000
