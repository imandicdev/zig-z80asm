"""Tests for smell_check.py: for every rule one case it must catch and one it
must not.

usage: python tools/test_smell_check.py
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import smell_check  # noqa: E402

SCRIPT = Path(__file__).parent / "smell_check.py"


def rules(source: str, path: str = "src/x.zig") -> list[str]:
    return [f.rule for f in smell_check.check_text(path, source)]


class MagicNumber(unittest.TestCase):
    def test_caught(self):
        self.assertEqual(rules("fn f() void {\n    g(42);\n}\n"), ["magic-number"])

    def test_not_caught(self):
        source = (
            "pub const max_passes = 8;\n"
            "const Options = struct {\n"
            "    max_symbols: usize = 2048,\n"
            "};\n"
            "fn f(x: u32) u32 {\n"
            "    return (x & 0xFF) + 0 + 1 + (x >> 0x10) + @as(u32, 0x7F);\n"
            "}\n"
            "test \"values\" {\n"
            "    try expect(f(300) == 44);\n"
            "}\n"
        )
        self.assertEqual(rules(source), [])

    def test_shift_amounts(self):
        self.assertEqual(rules("fn f(x: u32) u32 {\n    return (x >> 8) + (x << 3);\n}\n"), [])
        self.assertEqual(rules("fn f(x: u32) u32 {\n    return 16 << 20;\n}\n"), ["magic-number"])

    def test_radix(self):
        source = "fn f(s: []const u8) !u32 {\n    return std.fmt.parseInt(u32, s, 16) + parseDigits(s, 2);\n}\n"
        self.assertEqual(rules(source), [])
        self.assertEqual(rules("fn f(s: []const u8) bool {\n    return s.len > 2;\n}\n"), ["magic-number"])

    def test_table_in_named_constant(self):
        table = "const precedence = .{\n    .{ .op = .add, .level = 5 },\n    .{ .op = .mul, .level = 6 },\n};\n"
        single = "const widths = [_]u8{ 3, 5, 7 };\n"
        self.assertEqual(rules(table), [])
        self.assertEqual(rules(single), [])
        in_function = "fn level(op: Op) u8 {\n    return switch (op) {\n        .add => 5,\n        .mul => 6,\n    };\n}\n"
        self.assertEqual(rules(in_function), ["magic-number", "magic-number"])

    def test_opcodes_in_isa(self):
        self.assertEqual(rules("pub fn halt() Encoding {\n    return enc1(0x76);\n}\n", "src/isa.zig"), [])
        self.assertEqual(rules("pub fn halt() Encoding {\n    return enc1(0x76);\n}\n"), ["magic-number"])


class AlgorithmConstant(unittest.TestCase):
    def test_caught(self):
        self.assertEqual(rules("fn h() u32 {\n    var h: u32 = 0x811C9DC5;\n}\n"), ["algorithm-constant"])

    def test_not_caught(self):
        previous_line = "fn h() u32 {\n    // FNV-1a offset basis\n    var h: u32 = 0x811C9DC5;\n}\n"
        same_line = "fn h() u32 {\n    var h: u32 = 0x811C9DC5; // FNV-1a\n}\n"
        self.assertEqual(rules(previous_line), [])
        self.assertEqual(rules(same_line), [])

    def test_doc_comment_of_the_function(self):
        named = "/// FNV-1a over the lowercased bytes.\nfn h() u32 {\n    var h: u32 = 0x811C9DC5;\n}\n"
        other = "/// Hash of the bytes.\nfn h() u32 {\n    var h: u32 = 0x811C9DC5;\n}\n"
        self.assertEqual(rules(named), [])
        self.assertEqual(rules(other), ["algorithm-constant"])


class Banner(unittest.TestCase):
    def test_caught(self):
        self.assertEqual(rules("// ===== Parser =====\n"), ["banner"])
        self.assertEqual(rules("////////////\n"), ["banner"])

    def test_not_caught(self):
        self.assertEqual(rules("// a == b, --x, and x->y\n"), [])


class AiVocabulary(unittest.TestCase):
    def test_caught(self):
        self.assertEqual(rules("/// This function is robust.\n"), ["ai-vocabulary", "ai-vocabulary"])
        self.assertEqual(rules("// works ✅\n"), ["ai-vocabulary"])

    def test_not_caught(self):
        self.assertEqual(rules("/// The slot holding `name`, or the free slot where it belongs.\n"), [])


class CommentRatio(unittest.TestCase):
    def test_caught(self):
        source = "fn f() void {\n    // one\n    // two\n    // three\n    a();\n    b();\n}\n"
        self.assertEqual(rules(source), ["comment-ratio"])

    def test_not_caught(self):
        source = "fn f() void {\n    // why\n    a();\n    b();\n    c();\n    d();\n}\n"
        self.assertEqual(rules(source), [])


class Todo(unittest.TestCase):
    def test_caught(self):
        self.assertEqual(rules("// TODO\n"), ["todo"])
        self.assertEqual(rules("// FIXME: fix\n"), ["todo"])

    def test_not_caught(self):
        self.assertEqual(rules("// TODO: macros, needed for ZEXDOC\n"), [])


class Unreachable(unittest.TestCase):
    def test_caught(self):
        self.assertEqual(rules("const x = y orelse unreachable;\n"), ["unreachable"])

    def test_not_caught(self):
        same_line = "const x = y orelse unreachable; // set by init above\n"
        previous_line = "// init always sets y\nconst x = y orelse unreachable;\n"
        in_string = 'const s = "unreachable";\n'
        self.assertEqual(rules(same_line), [])
        self.assertEqual(rules(previous_line), [])
        self.assertEqual(rules(in_string), [])


class SmellOk(unittest.TestCase):
    def test_with_reason(self):
        self.assertEqual(rules("fn f() void {\n    g(42); // smell-ok: port 42 is fixed by the hardware\n}\n"), [])

    def test_without_reason(self):
        self.assertEqual(rules("fn f() void {\n    g(42); // smell-ok:\n}\n"), ["magic-number", "smell-ok"])


class Output(unittest.TestCase):
    def run_on(self, source: str):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "a.zig").write_text(source, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), d], capture_output=True, encoding="utf-8"
            )

    def test_findings(self):
        r = self.run_on("fn f() void {\n    g(42);\n}\n")
        self.assertEqual(r.returncode, 1)
        self.assertRegex(r.stdout, r"a\.zig:2 \[magic-number\]\n  Problem: .+\n  Obrazloženje: .+\n  Predlog: .+")

    def test_clean(self):
        r = self.run_on("fn f() void {}\n")
        self.assertEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
