; Labels, EQU, $ and forward references
    ORG 100h
start:
    LD HL,msg
    LD DE,msg+1
    LD BC,msg_end-msg
    JP later
loop    DJNZ loop
    JR start
    JR $
    JR $+4
    JR NZ,later
    JR 0x0118
    CALL later
    DW start,later,$
count EQU 3
size = count*2+1
    LD A,size
    LD A,count
    LD (buffer),A
later:
    RET
msg: DB "Hello",13,10,'$'
msg_end:
buffer: DS 4
    DB fwd_value
fwd_value EQU 0x42
