; These eight inputs used to assemble silently to wrong bytes (found by the
; feature probe before the rewrite). They must now match sjasmplus.
    ORG 0x100
    LD A,$FF
    LD A,%1010
    LD A,1010B
    LD A,2+3
    LD A,2*3
L1: LD HL,L1+1
    JR $
L2: DW L2
