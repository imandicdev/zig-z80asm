; INCBIN "name"[, offset[, length]] of incbin_data.dat, bytes 10 11 12 13.

        ORG 8000h
        INCBIN "incbin_data.dat"
        INCBIN "incbin_data.dat", 2
        INCBIN "incbin_data.dat", 1, 2
