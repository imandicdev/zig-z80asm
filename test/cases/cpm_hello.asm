; CP/M: prints a line through BDOS function 9 and returns to CP/M.

bdos            EQU 0005h
print_string    EQU 9

        ORG 0100h
start:  LD DE,message
        LD C,print_string
        CALL bdos
        JP 0            ; warm boot, back to CP/M

message:
        DB "hello",13,10,"$"

        END start
