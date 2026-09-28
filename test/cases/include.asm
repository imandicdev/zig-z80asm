; INCLUDE: the lines of the file are assembled in place, and its labels are
; labels of the program like any other.

        ORG 8000h
        DB 1
        INCLUDE "include_part.inc"
        DB 4
        DW part_label, nested_label
