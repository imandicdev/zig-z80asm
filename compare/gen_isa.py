"""Exhaustive encoder check: z80isa.zig vs sjasmplus vs the documented opcode list.

For every documented opcode in z80_documented_opcodes.txt this script
  1. substitutes concrete operands (n, nn, d, e),
  2. writes the instruction to out/isa_cases.asm for sjasmplus,
  3. maps it to the matching z80isa.zig encoder call (if one exists),
  4. runs sjasmplus and checks its bytes against the list's Hex column,
  5. writes isa_cases.zig, a Zig test that compares the encoder against sjasmplus.

Opcodes without an encoder function are reported as "no encoder" (coverage),
not as failures.

Usage (from the repository root):
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
DISPS = [5, -3]  # (IX+d) displacements
E = 5  # relative jump offset

R8 = {"B": ".b", "C": ".c", "D": ".d", "E": ".e", "H": ".h", "L": ".l", "(HL)": ".hl_ind", "A": ".a"}
R16 = {"BC": ".bc", "DE": ".de", "HL": ".hl", "SP": ".sp"}
R16AF = {"BC": ".bc", "DE": ".de", "HL": ".hl", "AF": ".af"}
CC = {"NZ": ".nz", "Z": ".z", "NC": ".nc", "C": ".cy", "PO": ".po", "PE": ".pe", "P": ".p", "M": ".m"}
ZERO_ARG = {
    "NOP": "nop", "HALT": "halt", "RET": "ret", "EI": "ei", "DI": "di", "EXX": "exx",
    "RLCA": "rlca", "RRCA": "rrca", "RLA": "rla", "RRA": "rra", "CPL": "cpl", "SCF": "scf",
    "CCF": "ccf", "DAA": "daa", "NEG": "neg", "RETI": "reti", "RETN": "retn",
    "LDIR": "ldir", "LDDR": "lddr", "CPIR": "cpir", "CPDR": "cpdr", "INIR": "inir", "OTIR": "otir",
    "EX AF,AF'": "ex_af", "EX DE,HL": "ex_de_hl", "EX (SP),HL": "ex_sp_hl", "LD SP,HL": "ld_sp_hl",
    "JP (HL)": "jp_hl", "IM 0": "im0", "IM 1": "im1", "IM 2": "im2", "LD I,A": "ld_i_a", "LD A,I": "ld_a_i",
    "LD A,(BC)": "ld_a_bc_ind", "LD A,(DE)": "ld_a_de_ind", "LD (BC),A": "ld_bc_ind_a", "LD (DE),A": "ld_de_ind_a",
    "INDR": "indr", "OTDR": "otdr", "LDI": "ldi", "LDD": "ldd", "CPI": "cpi", "CPD": "cpd",
    "INI": "ini", "IND": "ind", "OUTI": "outi", "OUTD": "outd", "RLD": "rld", "RRD": "rrd",
    "LD R,A": "ld_r_a", "LD A,R": "ld_a_r",
}
ALU_IDX = {"ADD A,": "add_a_idx_d", "ADC A,": "adc_a_idx_d", "SUB ": "sub_idx_d", "SBC A,": "sbc_a_idx_d",
           "AND ": "and_idx_d", "XOR ": "xor_idx_d", "OR ": "or_idx_d", "CP ": "cp_idx_d"}
ALU_R = {"ADD A,": "add_a_r", "ADC A,": "adc_a_r", "SUB ": "sub_r", "SBC A,": "sbc_a_r",
         "AND ": "and_r", "XOR ": "xor_r", "OR ": "or_r", "CP ": "cp_r"}
ALU_N = {"ADD A,": "add_a_n", "ADC A,": "adc_a_n", "SUB ": "sub_n", "SBC A,": "sbc_a_n",
         "AND ": "and_n", "XOR ": "xor_n", "OR ": "or_n", "CP ": "cp_n"}
CB_ROT = {"RLC": "rlc_r", "RRC": "rrc_r", "RL": "rl_r", "RR": "rr_r", "SLA": "sla_r", "SRA": "sra_r", "SRL": "srl_r"}
CB_BIT = {"BIT": "bit_op", "SET": "set_op", "RES": "res_op"}


def zig_call(m):
    """Map a concrete-operand-free mnemonic form (with n/nn/d/e placeholders) to a Zig
    expression template, or None if z80isa.zig has no encoder for it."""
    if m in ZERO_ARG:
        return ZERO_ARG[m] + "()"
    mo = re.fullmatch(r"LD (\w|\(HL\)),(\w|\(HL\))", m)
    if mo and mo.group(1) in R8 and mo.group(2) in R8:
        return "ld_r_r(%s, %s)" % (R8[mo.group(1)], R8[mo.group(2)])
    if m == "LD (HL),n":
        return "ld_hl_ind_n({n})"
    mo = re.fullmatch(r"LD (\w),n", m)
    if mo and mo.group(1) in R8:
        return "ld_r_n(%s, {n})" % R8[mo.group(1)]
    mo = re.fullmatch(r"LD (BC|DE|HL|SP),nn", m)
    if mo:
        return "ld_rr_nn(%s, {nn})" % R16[mo.group(1)]
    if m == "LD A,(nn)":
        return "ld_a_nn_ind({nn})"
    if m == "LD (nn),A":
        return "ld_nn_ind_a({nn})"
    mo = re.fullmatch(r"LD (BC|DE|HL|SP),\(nn\)", m)
    if mo:
        return "ld_rr_nn_ind(%s, {nn})" % R16[mo.group(1)]
    mo = re.fullmatch(r"LD \(nn\),(BC|DE|HL|SP)", m)
    if mo:
        return "ld_nn_ind_rr({nn}, %s)" % R16[mo.group(1)]
    mo = re.fullmatch(r"LD (IX|IY),nn", m)
    if mo:
        return "ld_idx_nn(.%s, {nn})" % mo.group(1).lower()
    mo = re.fullmatch(r"LD SP,(IX|IY)", m)
    if mo:
        return "ld_sp_idx(.%s)" % mo.group(1).lower()
    mo = re.fullmatch(r"LD \((IX|IY)\+d\),n", m)
    if mo:
        return "ld_idx_d_n(.%s, {d}, {n})" % mo.group(1).lower()
    mo = re.fullmatch(r"LD \((IX|IY)\+d\),(\w)", m)
    if mo and mo.group(2) in R8:
        return "ld_idx_d_r(.%s, {d}, %s)" % (mo.group(1).lower(), R8[mo.group(2)])
    mo = re.fullmatch(r"LD (\w),\((IX|IY)\+d\)", m)
    if mo and mo.group(1) in R8:
        return "ld_r_idx_d(%s, .%s, {d})" % (R8[mo.group(1)], mo.group(2).lower())
    mo = re.fullmatch(r"(PUSH|POP) (BC|DE|HL|AF)", m)
    if mo:
        return "%s(%s)" % (mo.group(1).lower(), R16AF[mo.group(2)])
    mo = re.fullmatch(r"(PUSH|POP) (IX|IY)", m)
    if mo:
        return "%s_idx(.%s)" % (mo.group(1).lower(), mo.group(2).lower())
    mo = re.fullmatch(r"(INC|DEC) (\w|\(HL\))", m)
    if mo and mo.group(2) in R8:
        return "%s_r(%s)" % (mo.group(1).lower(), R8[mo.group(2)])
    mo = re.fullmatch(r"(INC|DEC) (BC|DE|HL|SP)", m)
    if mo:
        return "%s_rr(%s)" % (mo.group(1).lower(), R16[mo.group(2)])
    for prefix, fn in ALU_R.items():
        if m.startswith(prefix):
            rest = m[len(prefix):]
            if rest in R8:
                return "%s(%s)" % (fn, R8[rest])
            if rest == "n":
                return "%s({n})" % ALU_N[prefix]
    mo = re.fullmatch(r"(ADD|ADC|SBC) HL,(BC|DE|HL|SP)", m)
    if mo:
        return "%s_hl_rr(%s)" % (mo.group(1).lower(), R16[mo.group(2)])
    mo = re.fullmatch(r"ADD (IX|IY),(BC|DE|IX|IY|SP)", m)
    if mo:
        src = mo.group(2)
        if src in ("IX", "IY"):
            if src != mo.group(1):
                return None
            src = "HL"  # ADD IX,IX encodes like ADD HL,HL
        return "add_idx_rr(.%s, %s)" % (mo.group(1).lower(), R16[src])
    if m == "JP nn":
        return "jp({nn})"
    mo = re.fullmatch(r"JP (\w\w?),nn", m)
    if mo and mo.group(1) in CC:
        return "jp_cc(%s, {nn})" % CC[mo.group(1)]
    mo = re.fullmatch(r"JP \((IX|IY)\)", m)
    if mo:
        return "jp_idx(.%s)" % mo.group(1).lower()
    if m == "JR e":
        return "jr({e})"
    mo = re.fullmatch(r"JR (NZ|Z|NC|C),e", m)
    if mo:
        return "jr_cc(%s, {e})" % CC[mo.group(1)]
    if m == "DJNZ e":
        return "djnz({e})"
    if m == "CALL nn":
        return "call({nn})"
    mo = re.fullmatch(r"CALL (\w\w?),nn", m)
    if mo and mo.group(1) in CC:
        return "call_cc(%s, {nn})" % CC[mo.group(1)]
    mo = re.fullmatch(r"RET (\w\w?)", m)
    if mo and mo.group(1) in CC:
        return "ret_cc(%s)" % CC[mo.group(1)]
    mo = re.fullmatch(r"RST ([0-9A-F]{2})h", m)
    if mo:
        return "rst(0x%s)" % mo.group(1)
    if m == "IN A,(n)":
        return "in_a_n({n})"
    if m == "OUT (n),A":
        return "out_n_a({n})"
    mo = re.fullmatch(r"IN (\w),\(C\)", m)
    if mo and mo.group(1) in R8:
        return "in_r_c(%s)" % R8[mo.group(1)]
    mo = re.fullmatch(r"OUT \(C\),(\w)", m)
    if mo and mo.group(1) in R8:
        return "out_c_r(%s)" % R8[mo.group(1)]
    mo = re.fullmatch(r"(RLC|RRC|RL|RR|SLA|SRA|SRL) (\w|\(HL\))", m)
    if mo and mo.group(2) in R8:
        return "%s(%s)" % (CB_ROT[mo.group(1)], R8[mo.group(2)])
    mo = re.fullmatch(r"(BIT|SET|RES) ([0-7]),(\w|\(HL\))", m)
    if mo and mo.group(3) in R8:
        return "%s(%s, %s)" % (CB_BIT[mo.group(1)], mo.group(2), R8[mo.group(3)])
    mo = re.fullmatch(r"EX \(SP\),(IX|IY)", m)
    if mo:
        return "ex_sp_idx(.%s)" % mo.group(1).lower()
    mo = re.fullmatch(r"LD (IX|IY),\(nn\)", m)
    if mo:
        return "ld_idx_nn_ind(.%s, {nn})" % mo.group(1).lower()
    mo = re.fullmatch(r"LD \(nn\),(IX|IY)", m)
    if mo:
        return "ld_nn_ind_idx({nn}, .%s)" % mo.group(1).lower()
    mo = re.fullmatch(r"(INC|DEC) (IX|IY)", m)
    if mo:
        return "%s_idx(.%s)" % (mo.group(1).lower(), mo.group(2).lower())
    mo = re.fullmatch(r"(INC|DEC) \((IX|IY)\+d\)", m)
    if mo:
        return "%s_idx_d(.%s, {d})" % (mo.group(1).lower(), mo.group(2).lower())
    for prefix, fn in ALU_IDX.items():
        mo = re.fullmatch(re.escape(prefix) + r"\((IX|IY)\+d\)", m)
        if mo:
            return "%s(.%s, {d})" % (fn, mo.group(1).lower())
    mo = re.fullmatch(r"(RLC|RRC|RL|RR|SLA|SRA|SRL) \((IX|IY)\+d\)", m)
    if mo:
        return "%s_idx_d(.%s, {d})" % (mo.group(1).lower(), mo.group(2).lower())
    mo = re.fullmatch(r"(BIT|SET|RES) ([0-7]),\((IX|IY)\+d\)", m)
    if mo:
        return "%s_idx_d(%s, .%s, {d})" % (mo.group(1).lower(), mo.group(2), mo.group(3).lower())
    return None


def parse_list(path):
    """Yield (hex_tokens, mnemonic) for every opcode row in the list."""
    rows = []
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if not re.match(r"^[0-9A-F]{2}( |$)", line):
            continue
        if "PREFIX" in line and "[" in line:
            continue  # prefix placeholder rows in the unprefixed table
        fields = re.split(r"\s{2,}", line.strip())
        hex_tokens = fields[0].split()
        mnem = fields[-2]
        mnem = re.sub(r"^\d+(/\d+)?\s+", "", mnem)  # T-states glued to the mnemonic (e.g. "13/8 DJNZ e")
        rows.append((hex_tokens, mnem.strip()))
    return rows


def expected_from_hex(hex_tokens, d):
    """Bytes the list says this opcode encodes to, with our concrete operands."""
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
    """Mnemonic text for sjasmplus with concrete operands."""
    s = mnem
    s = s.replace("+d)", ("+%d)" % d) if d >= 0 else ("%d)" % d))
    s = re.sub(r"\bnn\b", "0x%04X" % NN, s)
    s = re.sub(r"\bn\b", "0x%02X" % N, s)
    s = re.sub(r"\be\b", "$+%d" % (E + 2), s)  # target = $ + 2 + offset
    return s


def main():
    os.makedirs(OUT, exist_ok=True)
    rows = parse_list(os.path.join(HERE, "z80_documented_opcodes.txt"))

    cases = []  # (asm_text, expected_bytes_from_list, zig_expr_or_None, form)
    for hex_tokens, mnem in rows:
        # The Hex column often lists only the opcode bytes (e.g. "06" for LD B,n or
        # "ED 43" for LD (nn),BC). Append operand bytes implied by the mnemonic.
        needed = []
        if "+d)" in mnem:
            needed.append("d")
        if re.search(r"\bnn\b", mnem):
            needed.append("nn")
        elif re.search(r"\bn\b", mnem):
            needed.append("n")
        if re.search(r"\be\b", mnem):
            needed.append("e")
        hex_tokens = hex_tokens + [t for t in needed if t not in hex_tokens]
        for d in (DISPS if "+d)" in mnem else [0]):
            tmpl = zig_call(mnem)
            expr = None
            if tmpl is not None:
                expr = tmpl.format(n="0x%02X" % N, nn="0x%04X" % NN, d=str(d), e=str(E))
            cases.append((concretize(mnem, d), expected_from_hex(hex_tokens, d), expr, mnem))

    asm_path = os.path.join(OUT, "isa_cases.asm")
    bin_path = os.path.join(OUT, "isa_cases.bin")
    with open(asm_path, "w", newline="\n") as f:
        f.write("    ORG 0x0000\n")
        for asm, _, _, _ in cases:
            f.write("    %s\n" % asm)

    lst_path = os.path.join(OUT, "isa_cases.lst")
    r = subprocess.run([SJASM, "--nologo", "--raw=" + bin_path, "--lst=" + lst_path, asm_path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        sys.exit("sjasmplus failed")
    ref = open(bin_path, "rb").read()

    # Per-instruction bytes from the sjasmplus listing: "  NN   AAAA BB BB BB BB   text".
    # Source line 1 is ORG; case i is on source line i + 2.
    lst_bytes = {}
    for line in open(lst_path, encoding="latin-1"):
        mo = re.match(r"^\s*(\d+)\s+([0-9A-F]{4}) ((?:[0-9A-F]{2} ?)*)", line)
        if mo:
            lst_bytes[int(mo.group(1))] = (int(mo.group(2), 16), [int(x, 16) for x in mo.group(3).split()])

    list_mismatch = []
    offsets = []
    lengths = []
    for i, (asm, exp, _, _) in enumerate(cases):
        addr, got = lst_bytes[i + 2]
        if list(ref[addr:addr + len(got)]) != got:
            sys.exit("listing and raw output disagree at line %d" % (i + 2))
        if got != exp:
            list_mismatch.append((asm, exp, got))
        offsets.append(addr)
        lengths.append(len(got))

    # Emit the Zig comparison test.
    zig_path = os.path.join(HERE, "isa_cases.zig")
    with open(zig_path, "w", newline="\n") as f:
        f.write("// GENERATED by compare/gen_isa.py -- do not edit.\n")
        f.write("// Compares z80isa.zig encoders against sjasmplus output (out/isa_cases.bin).\n")
        f.write("const std = @import(\"std\");\n")
        f.write("const isa = @import(\"z80isa\");\n\n")
        f.write("const Case = struct { asm_text: []const u8, off: usize, len: usize, enc: isa.Encoding };\n\n")
        f.write("const cases = blk: {\n")
        f.write("    @setEvalBranchQuota(100_000);\n")
        f.write("    break :blk [_]Case{\n")
        for (asm, _, expr, _), o, n in zip(cases, offsets, lengths):
            if expr is None:
                continue
            f.write("        .{ .asm_text = \"%s\", .off = %d, .len = %d, .enc = isa.%s },\n" % (asm, o, n, expr))
        f.write("    };\n};\n\n")
        f.write(
            "fn printHex(bytes: []const u8) void {\n"
            "    for (bytes) |b| std.debug.print(\" {X:0>2}\", .{b});\n"
            "}\n\n"
            "test \"z80isa encoders match sjasmplus\" {\n"
            "    const ref = @embedFile(\"out/isa_cases.bin\");\n"
            "    var failures: usize = 0;\n"
            "    for (cases) |c| {\n"
            "        const want = ref[c.off..][0..c.len];\n"
            "        const got = c.enc.bytes[0..c.enc.len];\n"
            "        if (!std.mem.eql(u8, want, got)) {\n"
            "            failures += 1;\n"
            "            std.debug.print(\"MISMATCH {s}: sjasmplus\", .{c.asm_text});\n"
            "            printHex(want);\n"
            "            std.debug.print(\"  z80isa\", .{});\n"
            "            printHex(got);\n"
            "            std.debug.print(\"\\n\", .{});\n"
            "        }\n"
            "    }\n"
            "    std.debug.print(\"z80isa vs sjasmplus: {d} cases, {d} mismatches\\n\", .{ cases.len, failures });\n"
            "    try std.testing.expectEqual(@as(usize, 0), failures);\n"
            "}\n"
        )

    # Coverage report.
    forms = {}
    for _, _, expr, form in cases:
        forms.setdefault(form, expr is not None)
    missing = sorted(f for f, ok in forms.items() if not ok)
    covered = len(forms) - len(missing)
    with open(os.path.join(HERE, "isa_coverage.txt"), "w", newline="\n") as f:
        f.write("Documented opcodes: %d (from z80_documented_opcodes.txt)\n" % len(forms))
        f.write("With a z80isa.zig encoder: %d\n" % covered)
        f.write("Without an encoder: %d\n\n" % len(missing))
        for m in missing:
            f.write("  %s\n" % m)

    print("opcodes in list: %d, test cases: %d, sjasmplus bytes: %d" % (len(forms), len(cases), len(ref)))
    print("list vs sjasmplus mismatches: %d" % len(list_mismatch))
    for asm, exp, got in list_mismatch:
        print("  %-22s list %s  sjasmplus %s" % (asm, " ".join("%02X" % b for b in exp), " ".join("%02X" % b for b in got)))
    print("encoder coverage: %d of %d forms (%d without encoder, see compare/isa_coverage.txt)" % (covered, len(forms), len(missing)))


if __name__ == "__main__":
    main()
