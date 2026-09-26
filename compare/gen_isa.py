"""Exhaustive encoder check: isa.zig vs sjasmplus vs the documented opcode list.

Every opcode in z80_documented_opcodes.txt gets concrete operands, is assembled
by sjasmplus, and is mapped to the matching isa.zig call. The generated Zig test
(isa_cases.zig) compares the two byte for byte. sjasmplus is also checked
against the list's Hex column, so a mistake in the list shows up too.

Usage, from the repository root:
    python compare/gen_isa.py && zig build compare-isa
"""

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
SJASM = os.path.join(HERE, "..", "tools", "sjasmplus", "sjasmplus-1.24.0.win", "sjasmplus.exe")

N = 0x5A
NN = 0x1234
DISPS = [5, -3]
E = 5

R8 = {"B": ".b", "C": ".c", "D": ".d", "E": ".e", "H": ".h", "L": ".l", "(HL)": ".hl_mem", "A": ".a"}
R16 = {"BC": ".bc", "DE": ".de", "HL": ".hl", "SP": ".sp"}
R16AF = {"BC": ".bc", "DE": ".de", "HL": ".hl", "AF": ".af"}
CC = {"NZ": ".nz", "Z": ".z", "NC": ".nc", "C": ".c", "PO": ".po", "PE": ".pe", "P": ".p", "M": ".m"}
ALU = {"ADD A,": ".add", "ADC A,": ".adc", "SUB ": ".sub", "SBC A,": ".sbc",
       "AND ": ".@\"and\"", "XOR ": ".xor", "OR ": ".@\"or\"", "CP ": ".cp"}
ROT = "RLC|RRC|RL|RR|SLA|SRA|SRL"

FIXED = {
    "NOP": "nop()", "HALT": "halt()", "EI": "ei()", "DI": "di()", "EXX": "exx()",
    "EX AF,AF'": "exAf()", "EX DE,HL": "exDeHl()", "EX (SP),HL": "exSpHl()",
    "RLCA": "rlca()", "RRCA": "rrca()", "RLA": "rla()", "RRA": "rra()",
    "DAA": "daa()", "CPL": "cpl()", "SCF": "scf()", "CCF": "ccf()",
    "NEG": "neg()", "RETN": "retn()", "RETI": "reti()", "RRD": "rrd()", "RLD": "rld()",
    "IM 0": "im(0)", "IM 1": "im(1)", "IM 2": "im(2)",
    "LD I,A": "ldIA()", "LD R,A": "ldRA()", "LD A,I": "ldAI()", "LD A,R": "ldAR()",
    "LDI": "ldi()", "CPI": "cpi()", "INI": "ini()", "OUTI": "outi()",
    "LDD": "ldd()", "CPD": "cpd()", "IND": "ind()", "OUTD": "outd()",
    "LDIR": "ldir()", "CPIR": "cpir()", "INIR": "inir()", "OTIR": "otir()",
    "LDDR": "lddr()", "CPDR": "cpdr()", "INDR": "indr()", "OTDR": "otdr()",
    "LD A,(BC)": "ldABc()", "LD A,(DE)": "ldADe()", "LD (BC),A": "ldBcA()", "LD (DE),A": "ldDeA()",
    "LD A,(nn)": "ldAMem({nn})", "LD (nn),A": "ldMemA({nn})", "LD SP,HL": "ldSpHl()",
    "JP nn": "jp({nn})", "JP (HL)": "jpHl()", "CALL nn": "call({nn})", "RET": "ret()",
    "JR e": "jr({e})", "DJNZ e": "djnz({e})",
    "IN A,(n)": "inAN({n})", "OUT (n),A": "outNA({n})",
}

# (pattern, template); groups are substituted with the tables above.
RULES = [
    (r"LD (\w|\(HL\)),(\w|\(HL\))", lambda g: g[0] in R8 and g[1] in R8 and "ldRR(%s, %s)" % (R8[g[0]], R8[g[1]])),
    (r"LD (\w|\(HL\)),n", lambda g: g[0] in R8 and "ldRN(%s, {n})" % R8[g[0]]),
    (r"LD (BC|DE|HL|SP),nn", lambda g: "ldRrNn(%s, {nn})" % R16[g[0]]),
    (r"LD (BC|DE|HL|SP),\(nn\)", lambda g: "ldRrMem(%s, {nn})" % R16[g[0]]),
    (r"LD \(nn\),(BC|DE|HL|SP)", lambda g: "ldMemRr({nn}, %s)" % R16[g[0]]),
    (r"LD (IX|IY),nn", lambda g: "ldIdxNn(.%s, {nn})" % g[0].lower()),
    (r"LD (IX|IY),\(nn\)", lambda g: "ldIdxMem(.%s, {nn})" % g[0].lower()),
    (r"LD \(nn\),(IX|IY)", lambda g: "ldMemIdx({nn}, .%s)" % g[0].lower()),
    (r"LD SP,(IX|IY)", lambda g: "ldSpIdx(.%s)" % g[0].lower()),
    (r"LD \((IX|IY)\+d\),n", lambda g: "ldIdxDN(.%s, {d}, {n})" % g[0].lower()),
    (r"LD \((IX|IY)\+d\),(\w)", lambda g: g[1] in R8 and "ldIdxDR(.%s, {d}, %s)" % (g[0].lower(), R8[g[1]])),
    (r"LD (\w),\((IX|IY)\+d\)", lambda g: g[0] in R8 and "ldRIdxD(%s, .%s, {d})" % (R8[g[0]], g[1].lower())),
    (r"(PUSH|POP) (BC|DE|HL|AF)", lambda g: "%s(%s)" % (g[0].lower(), R16AF[g[1]])),
    (r"(PUSH|POP) (IX|IY)", lambda g: "%sIdx(.%s)" % (g[0].lower(), g[1].lower())),
    (r"(INC|DEC) (\w|\(HL\))", lambda g: g[1] in R8 and "%sR(%s)" % (g[0].lower(), R8[g[1]])),
    (r"(INC|DEC) (BC|DE|HL|SP)", lambda g: "%sRr(%s)" % (g[0].lower(), R16[g[1]])),
    (r"(INC|DEC) (IX|IY)", lambda g: "%sIdx(.%s)" % (g[0].lower(), g[1].lower())),
    (r"(INC|DEC) \((IX|IY)\+d\)", lambda g: "%sIdxD(.%s, {d})" % (g[0].lower(), g[1].lower())),
    (r"(ADD|ADC|SBC) HL,(BC|DE|HL|SP)", lambda g: "%sHlRr(%s)" % (g[0].lower(), R16[g[1]])),
    (r"ADD (IX|IY),(BC|DE|IX|IY|SP)", lambda g: add_idx(g[0], g[1])),
    (r"JP (\w\w?),nn", lambda g: g[0] in CC and "jpCc(%s, {nn})" % CC[g[0]]),
    (r"JP \((IX|IY)\)", lambda g: "jpIdx(.%s)" % g[0].lower()),
    (r"JR (NZ|Z|NC|C),e", lambda g: "jrCc(%s, {e})" % CC[g[0]]),
    (r"CALL (\w\w?),nn", lambda g: g[0] in CC and "callCc(%s, {nn})" % CC[g[0]]),
    (r"RET (\w\w?)", lambda g: g[0] in CC and "retCc(%s)" % CC[g[0]]),
    (r"RST ([0-9A-F]{2})h", lambda g: "rst(0x%s)" % g[0]),
    (r"IN (\w),\(C\)", lambda g: g[0] in R8 and "inRC(%s)" % R8[g[0]]),
    (r"OUT \(C\),(\w)", lambda g: g[0] in R8 and "outCR(%s)" % R8[g[0]]),
    (r"(%s) (\w|\(HL\))" % ROT, lambda g: g[1] in R8 and "rot(.%s, %s)" % (g[0].lower(), R8[g[1]])),
    (r"(%s) \((IX|IY)\+d\)" % ROT, lambda g: "rotIdxD(.%s, .%s, {d})" % (g[0].lower(), g[1].lower())),
    (r"(BIT|SET|RES) ([0-7]),(\w|\(HL\))", lambda g: g[2] in R8 and "%s(%s, %s)" % (g[0].lower(), g[1], R8[g[2]])),
    (r"(BIT|SET|RES) ([0-7]),\((IX|IY)\+d\)", lambda g: "%sIdxD(%s, .%s, {d})" % (g[0].lower(), g[1], g[2].lower())),
    (r"EX \(SP\),(IX|IY)", lambda g: "exSpIdx(.%s)" % g[0].lower()),
]


def add_idx(idx, src):
    if src in ("IX", "IY"):
        if src != idx:
            return None
        src = "HL"  # ADD IX,IX uses the ADD HL,HL slot
    return "addIdxRr(.%s, %s)" % (idx.lower(), R16[src])


def zig_call(m):
    """isa.zig call template for a mnemonic form, or None if there is no encoder."""
    if m in FIXED:
        return FIXED[m]
    for prefix, op in ALU.items():
        if m.startswith(prefix):
            rest = m[len(prefix):]
            if rest in R8:
                return "aluR(%s, %s)" % (op, R8[rest])
            if rest == "n":
                return "aluN(%s, {n})" % op
            mo = re.fullmatch(r"\((IX|IY)\+d\)", rest)
            if mo:
                return "aluIdxD(%s, .%s, {d})" % (op, mo.group(1).lower())
    for pattern, build in RULES:
        mo = re.fullmatch(pattern, m)
        if mo and build(mo.groups()):
            return build(mo.groups())
    return None


def undocumented_cases():
    """(asm, isa call) for the undocumented forms isa.zig supports. They are not
    in the opcode list, so they are checked against sjasmplus only."""
    regs = ["B", "C", "D", "E", "H", "L", "(HL)", "A"]
    plain = ["A", "B", "C", "D", "E"]
    out = [("SLL %s" % r, "rot(.sll, %s)" % R8[r]) for r in regs]
    for idx in ("IX", "IY"):
        i = "." + idx.lower()
        for d in DISPS:
            asm_d = ("+%d" % d) if d >= 0 else str(d)
            out.append(("SLL (%s%s)" % (idx, asm_d), "rotIdxD(.sll, %s, %d)" % (i, d)))
        halves = {idx + "H": ".h", idx + "L": ".l"}
        for half, hl in halves.items():
            ix = "indexHalf(%s, isa.%%s)" % i
            out.append(("LD %s,0x%02X" % (half, N), ix % ("ldRN(%s, 0x%02X)" % (hl, N))))
            out.append(("INC %s" % half, ix % ("incR(%s)" % hl)))
            out.append(("DEC %s" % half, ix % ("decR(%s)" % hl)))
            for r in plain:
                out.append(("LD %s,%s" % (r, half), ix % ("ldRR(%s, %s)" % (R8[r], hl))))
                out.append(("LD %s,%s" % (half, r), ix % ("ldRR(%s, %s)" % (hl, R8[r]))))
            for src, shl in halves.items():
                out.append(("LD %s,%s" % (half, src), ix % ("ldRR(%s, %s)" % (hl, shl))))
            for prefix, op in ALU.items():
                out.append(("%s%s" % (prefix, half), ix % ("aluR(%s, %s)" % (op, hl))))
    out.append(("IN F,(C)", "inFC()"))
    out.append(("OUT (C),0", "outC0()"))
    return out


def parse_list(path):
    """(hex tokens, mnemonic) for every opcode row in the list."""
    rows = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not re.match(r"^[0-9A-F]{2}( |$)", line) or ("PREFIX" in line and "[" in line):
            continue
        fields = re.split(r"\s{2,}", line.strip())
        # In the unprefixed table the T-states can touch the mnemonic ("13/8 DJNZ e").
        mnem = re.sub(r"^\d+(/\d+)?\s+", "", fields[-2]).strip()
        rows.append((fields[0].split(), mnem))
    return rows


def operand_bytes(mnem):
    """Operand placeholders implied by the mnemonic, in encoding order."""
    needed = []
    if "+d)" in mnem:
        needed.append("d")
    if re.search(r"\bnn\b", mnem):
        needed.append("nn")
    elif re.search(r"\bn\b", mnem):
        needed.append("n")
    if re.search(r"\be\b", mnem):
        needed.append("e")
    return needed


def expected_bytes(hex_tokens, d):
    out = []
    for t in hex_tokens:
        if t == "nn":
            out += [NN & 0xFF, NN >> 8]
        elif t == "n":
            out.append(N)
        elif t == "d":
            out.append(d & 0xFF)
        elif t == "e":
            out.append(E & 0xFF)
        else:
            out.append(int(t, 16))
    return out


def concretize(mnem, d):
    s = mnem.replace("+d)", ("+%d)" % d) if d >= 0 else ("%d)" % d))
    s = re.sub(r"\bnn\b", "0x%04X" % NN, s)
    s = re.sub(r"\bn\b", "0x%02X" % N, s)
    return re.sub(r"\be\b", "$+%d" % (E + 2), s)


def run_sjasmplus(asm_path, bin_path, lst_path):
    r = subprocess.run([SJASM, "--nologo", "--raw=" + bin_path, "--lst=" + lst_path, asm_path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        sys.exit("sjasmplus failed")
    listing = {}
    for line in open(lst_path, encoding="latin-1"):
        mo = re.match(r"^\s*(\d+)\s+([0-9A-F]{4}) ((?:[0-9A-F]{2} ?)*)", line)
        if mo:
            listing[int(mo.group(1))] = (int(mo.group(2), 16), [int(x, 16) for x in mo.group(3).split()])
    return open(bin_path, "rb").read(), listing


def write_zig_test(path, cases):
    with open(path, "w", newline="\n") as f:
        f.write("// Generated by compare/gen_isa.py.\n")
        f.write("const std = @import(\"std\");\n")
        f.write("const isa = @import(\"isa\");\n\n")
        f.write("const Case = struct { text: []const u8, off: usize, len: usize, enc: isa.Encoding };\n\n")
        f.write("const cases = blk: {\n    @setEvalBranchQuota(100_000);\n    break :blk [_]Case{\n")
        for c in cases:
            if c["expr"]:
                f.write("        .{ .text = \"%s\", .off = %d, .len = %d, .enc = isa.%s },\n"
                        % (c["asm"], c["off"], c["len"], c["expr"]))
        f.write("    };\n};\n\n")
        f.write(
            "fn printHex(bytes: []const u8) void {\n"
            "    for (bytes) |b| std.debug.print(\" {X:0>2}\", .{b});\n"
            "}\n\n"
            "test \"isa encoders match sjasmplus\" {\n"
            "    const ref = @embedFile(\"out/isa_cases.bin\");\n"
            "    var mismatches: usize = 0;\n"
            "    for (cases) |c| {\n"
            "        const want = ref[c.off..][0..c.len];\n"
            "        if (std.mem.eql(u8, want, c.enc.slice())) continue;\n"
            "        mismatches += 1;\n"
            "        std.debug.print(\"MISMATCH {s}: sjasmplus\", .{c.text});\n"
            "        printHex(want);\n"
            "        std.debug.print(\"  isa\", .{});\n"
            "        printHex(c.enc.slice());\n"
            "        std.debug.print(\"\\n\", .{});\n"
            "    }\n"
            "    std.debug.print(\"isa vs sjasmplus: {d} cases, {d} mismatches\\n\", .{ cases.len, mismatches });\n"
            "    try std.testing.expectEqual(0, mismatches);\n"
            "}\n"
        )


def main():
    os.makedirs(OUT, exist_ok=True)
    cases = []
    for hex_tokens, mnem in parse_list(os.path.join(HERE, "z80_documented_opcodes.txt")):
        hex_tokens = hex_tokens + [t for t in operand_bytes(mnem) if t not in hex_tokens]
        tmpl = zig_call(mnem)
        for d in (DISPS if "+d)" in mnem else [0]):
            expr = tmpl and tmpl.format(n="0x%02X" % N, nn="0x%04X" % NN, d=d, e=E)
            cases.append({"form": mnem, "asm": concretize(mnem, d), "list": expected_bytes(hex_tokens, d), "expr": expr})
    documented = len(cases)
    for asm, expr in undocumented_cases():
        cases.append({"form": None, "asm": asm, "list": None, "expr": expr})

    asm_path = os.path.join(OUT, "isa_cases.asm")
    with open(asm_path, "w", newline="\n") as f:
        f.write("    ORG 0x0000\n")
        for c in cases:
            f.write("    %s\n" % c["asm"])
    ref, listing = run_sjasmplus(asm_path, os.path.join(OUT, "isa_cases.bin"), os.path.join(OUT, "isa_cases.lst"))

    # Source line 1 is ORG, so case i is on line i + 2.
    list_mismatches = []
    for i, c in enumerate(cases):
        addr, got = listing[i + 2]
        if list(ref[addr:addr + len(got)]) != got:
            sys.exit("listing and raw output disagree at line %d" % (i + 2))
        c["off"], c["len"] = addr, len(got)
        if c["list"] is not None and got != c["list"]:
            list_mismatches.append((c["asm"], c["list"], got))

    write_zig_test(os.path.join(HERE, "isa_cases.zig"), cases)

    forms = {}
    for c in cases[:documented]:
        forms.setdefault(c["form"], c["expr"] is not None)
    missing = sorted(f for f, ok in forms.items() if not ok)
    with open(os.path.join(HERE, "isa_coverage.txt"), "w", newline="\n") as f:
        f.write("Documented opcodes: %d (from z80_documented_opcodes.txt)\n" % len(forms))
        f.write("With an isa.zig encoder: %d\n" % (len(forms) - len(missing)))
        f.write("Without an encoder: %d\n" % len(missing))
        for m in missing:
            f.write("  %s\n" % m)
        f.write("Undocumented cases (checked against sjasmplus only): %d\n" % (len(cases) - documented))

    print("opcodes in list: %d, test cases: %d, sjasmplus bytes: %d" % (len(forms), len(cases), len(ref)))
    print("list vs sjasmplus mismatches: %d" % len(list_mismatches))
    for asm, exp, got in list_mismatches:
        print("  %-22s list %s  sjasmplus %s" % (asm, " ".join("%02X" % b for b in exp), " ".join("%02X" % b for b in got)))
    print("encoder coverage: %d of %d forms" % (len(forms) - len(missing), len(forms)))
    print("undocumented cases: %d" % (len(cases) - documented))


if __name__ == "__main__":
    main()
