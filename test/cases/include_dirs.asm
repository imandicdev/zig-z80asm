; INCLUDE names are relative to the file that names them: both parts include
; "data.inc", and each gets the one in its own directory.

        ORG 8000h
        INCLUDE "include_dirs/left/part.inc"
        INCLUDE "include_dirs/right/part.inc"
