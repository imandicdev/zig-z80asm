; CP/M: prints a line through BDOS function 9 and returns to the CCP.
; `zig build cpm -Dcpm2sim=PATH` runs it in the simulator.

bdos            EQU 0005h
print_string    EQU 9

        ORG 0100h
start:  LD DE,message
        LD C,print_string
        CALL bdos
        RET

message:
        DB "hello",13,10,"$"

        END start
