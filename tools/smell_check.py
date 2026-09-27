"""Code smell check for the Zig sources, for CI and before a push.

usage: python tools/smell_check.py [PATH ...]    (default: src)

Rules:
  magic-number        a number outside a named constant; allowed are 0, 1, bit
                      masks, shift amounts, 2, 8, 10 and 16 as the base of a
                      number, the hex opcodes in isa.zig, tables that are the
                      value of a named constant and anything in a test block
  algorithm-constant  a known FNV, Fibonacci hashing or CRC constant, unless a
                      comment on the same or the previous line, or the doc
                      comment of the function it is in, names the algorithm
  banner              a comment with a run of repeated characters (// =====)
  ai-vocabulary       "robust", "comprehensive", "seamless", "leverage",
                      "ensure that", "This function", "Note that" or an emoji
                      in a comment
  comment-ratio       a function whose body is more than MAX_COMMENT_RATIO
                      comment lines
  todo                TODO or FIXME without an explanation
  unreachable         unreachable without an explanation in a comment on the
                      same or the previous line

"// smell-ok: <reason>" on a line suppresses its findings; without a reason it
is a finding itself. Exit code 1 when there are findings.
"""

import re
import sys
from dataclasses import dataclass
from pathlib import Path

MAX_COMMENT_RATIO = 0.4
# Shorter functions have too few lines for a ratio to mean anything.
MIN_FUNCTION_LINES = 5
# "TODO: fix" or "unreachable // above" do not say why.
MIN_EXPLANATION_WORDS = 2
BANNER_RUN = 4
ALLOWED_NUMBERS = {0, 1}
RADIXES = {2, 8, 10, 16}
OPCODE_FILE = "isa.zig"
DEFAULT_PATHS = ["src"]
SKIPPED_DIRS = {".zig-cache", "zig-out"}

ALGORITHMS = {
    "FNV": {
        "names": ("fnv",),
        "values": {0x811C9DC5, 0x01000193, 0xCBF29CE484222325, 0x100000001B3},
        "suggestion": "ili upotrebi std.hash.Fnv1a_32 / Fnv1a_64",
    },
    "Fibonacci hashing": {
        "names": ("fibonacci", "golden ratio"),
        "values": {0x9E3779B9, 0x9E3779B97F4A7C15, 0x61C88647},
        "suggestion": "",
    },
    "CRC": {
        "names": ("crc",),
        "values": {0xEDB88320, 0x04C11DB7, 0x82F63B78, 0x1EDC6F41, 0x1021, 0x8408, 0xA001, 0x8005},
        "suggestion": "ili upotrebi std.hash.Crc32 / std.hash.crc",
    },
}

AI_PHRASES = [
    (re.compile(r"\brobust(ly|ness)?\b", re.I), "robust",
     "Napiši šta tačno kod podnosi: koje ulaze, koje greške."),
    (re.compile(r"\bcomprehensive(ly)?\b", re.I), "comprehensive",
     "Nabroj šta je obuhvaćeno umesto ocene."),
    (re.compile(r"\bseamless(ly)?\b", re.I), "seamless",
     "Napiši šta se konkretno dešava, bez ocene."),
    (re.compile(r"\bleverag(e|es|ed|ing)\b", re.I), "leverage",
     "Napiši \"uses\" i šta se koristi."),
    (re.compile(r"\bensure that\b", re.I), "ensure that",
     "Napiši šta se proverava i šta se desi kad ne važi."),
    (re.compile(r"\bthis function\b", re.I), "This function",
     "Počni onim što funkcija vraća ili radi; da je funkcija, vidi se iz koda."),
    (re.compile(r"\bnote that\b", re.I), "Note that",
     "Izbaci uvod i napiši samu napomenu."),
]
EMOJI = re.compile("[\U0001F000-\U0001FAFF☀-➿⬀-⯿️]")

NUMBER = re.compile(
    r"(?<![\w@])(0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?)(?!\w)"
)
CONST_DECL = re.compile(r"^\s*(?:pub\s+)?const\s+\w+\s*(?::[^=]+)?=\s*(?P<init>[^;]*);")
FIELD_DEFAULT = re.compile(r"^\s*\w+\s*:[^=]+=\s*(?P<init>[^,]*),\s*$")
CONST_START = re.compile(r"^\s*(?:pub\s+)?const\s+\w+\s*(?::[^=]+)?=\s*(?P<init>.*)$")
TABLE_INIT = re.compile(r"\.\{|\[[^\]]*\][\w.?]*\{")
TOP_CONST = re.compile(r"^(?:pub\s+)?const\s+(\w+)\s*(?::[^=]+)?=")
IDENT = re.compile(r"[A-Za-z_]\w*")
# A call whose number arguments can be the base of a number: parseInt(T, s, 16).
RADIX_CALL = re.compile(r"parse|radix|base|digit|format", re.I)
SHIFTS = ("<<", ">>", "<<=", ">>=", "<<|", "<<|=")
OPERATORS_ONLY = re.compile(r"[\s+\-*/%<>()|&^~]*")
FN_DECL = re.compile(r"\bfn\s+(\w+|@\"[^\"]*\")\s*\(")
TEST_DECL = re.compile(r"^\s*test\b")
BANNER = re.compile(r"([=\-*#~_+/])\1{%d,}" % (BANNER_RUN - 1))
TODO = re.compile(r"\b(TODO|FIXME)\b(?P<rest>.*)")
UNREACHABLE = re.compile(r"\bunreachable\b")
SMELL_OK = re.compile(r"smell-ok\b:?(?P<reason>.*)$")
WORD = re.compile(r"[^\W_]+")


@dataclass
class Finding:
    path: str
    line: int
    rule: str
    problem: str
    reason: str
    suggestion: str

    def format(self) -> str:
        return (
            f"{self.path}:{self.line} [{self.rule}]\n"
            f"  Problem: {self.problem}\n"
            f"  Obrazloženje: {self.reason}\n"
            f"  Predlog: {self.suggestion}\n"
        )


@dataclass
class Line:
    code: str  # string and character literals emptied
    comment: str | None  # text after //, without the extra / or ! of doc comments
    doc: bool = False  # a /// comment


def split_line(text: str) -> Line:
    if text.lstrip().startswith("\\\\"):  # a line of a multiline string
        return Line("", None)
    code = []
    i = 0
    while i < len(text):
        c = text[i]
        if c in "\"'":
            j = i + 1
            while j < len(text) and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            code.append(c + c)
            i = j + 1
        elif text.startswith("//", i):
            comment = text[i + 2 :]
            doc = comment[:1] == "/" and comment[1:2] != "/"
            if comment[:1] in ("/", "!"):  # /// and //! doc comments
                comment = comment[1:]
            return Line("".join(code), comment, doc)
        else:
            code.append(c)
            i += 1
    return Line("".join(code), None)


def number_value(literal: str) -> float:
    s = literal.replace("_", "").lower()
    if s.startswith(("0x", "0b", "0o")):
        return int(s[2:], {"x": 16, "b": 2, "o": 8}[s[1]])
    return float(s) if any(ch in s for ch in ".e") else int(s)


def enclosing_call(code: str, start: int) -> str | None:
    """The name of the call whose argument list holds position `start`."""
    level = 0
    for i in range(start - 1, -1, -1):
        if code[i] == ")":
            level += 1
        elif code[i] == "(":
            if level == 0:
                name = re.search(r"([\w.]+)\s*$", code[:i])
                return name.group(1) if name else None
            level -= 1
    return None


def is_radix(value, code: str, start: int, end: int) -> bool:
    if value not in RADIXES:
        return False
    before = code[:start].rstrip()
    after = code[end:].lstrip()
    if not before.endswith((",", "(")) or not after.startswith((",", ")")):
        return False
    call = enclosing_call(code, start)
    return call is not None and RADIX_CALL.search(call) is not None


def is_shift_amount(code: str, start: int) -> bool:
    return code[:start].rstrip().endswith(SHIFTS)


def is_mask(literal: str, value, code: str, start: int, end: int) -> bool:
    if literal[:2].lower() in ("0x", "0b") and value >= 2:
        if value & (value - 1) == 0 or value & (value + 1) == 0:
            return True
    before = code[:start].rstrip()
    after = code[end:].lstrip()
    return before.endswith(("&", "|", "^", "~", "&=", "|=", "^=")) or after.startswith(("&", "|", "^"))


def is_named_constant(code: str, top_consts: set[str]) -> bool:
    """A const declaration or a field default whose value is a table, or numbers
    and operators, possibly with constants declared at the top of the file."""
    m = CONST_DECL.match(code) or FIELD_DEFAULT.match(code)
    if not m:
        return False
    init = m["init"].strip()
    if TABLE_INIT.search(init):
        return True
    rest = NUMBER.sub("", init)
    return OPERATORS_ONLY.fullmatch(IDENT.sub("", rest)) is not None and set(IDENT.findall(rest)) <= top_consts


def explained(comment: str | None) -> bool:
    return comment is not None and len(WORD.findall(comment)) >= MIN_EXPLANATION_WORDS


def check_text(path: str, text: str) -> list[Finding]:
    lines = [split_line(t) for t in text.split("\n")]
    top_consts = {m.group(1) for line in lines if (m := TOP_CONST.match(line.code))}
    in_opcode_file = Path(path).name == OPCODE_FILE
    findings: list[Finding] = []

    def add(line_no, rule, problem, reason, suggestion):
        findings.append(Finding(path, line_no, rule, problem, reason, suggestion))

    depth = 0
    test_depths: list[int] = []  # depth outside each open test block
    pending_fn = None  # (name, line number, depth, doc) of a signature without its body yet
    functions: list[dict] = []
    table_depth = None  # depth outside the multiline table a named constant is set to

    for index, line in enumerate(lines):
        line_no = index + 1
        code = line.code
        previous = lines[index - 1] if index > 0 else Line("", None)
        depth_before = depth
        if TEST_DECL.match(code):
            test_depths.append(depth_before)
        in_test = bool(test_depths)
        const = CONST_START.match(code)
        if table_depth is None and const and TABLE_INIT.search(const["init"].strip()):
            table_depth = depth_before
        in_table = table_depth is not None

        # Numbers: algorithm constants first, then magic numbers.
        for m in NUMBER.finditer(code):
            literal = m.group(1)
            start, end = m.span(1)
            if start > 0 and code[start - 1] == "." and not code[max(0, start - 2) : start] == "..":
                continue  # tuple field such as x.0
            value = number_value(literal)
            opcode = in_opcode_file and literal[:2].lower() == "0x"
            algorithm = next((n for n, a in ALGORITHMS.items() if value in a["values"]), None)
            if algorithm and not in_test and not opcode:
                names = ALGORITHMS[algorithm]["names"]
                docs = [f["doc"] for f in functions]
                comments = " ".join(c.lower() for c in (line.comment, previous.comment, *docs) if c)
                if not any(n in comments for n in names):
                    extra = ALGORITHMS[algorithm]["suggestion"]
                    add(line_no, "algorithm-constant",
                        f"konstanta algoritma {algorithm} ({literal}) bez imena algoritma u komentaru",
                        "Ko ne prepozna konstantu vidi proizvoljan broj; ime algoritma kaže odakle broj "
                        "dolazi i da se ne menja.",
                        f"Napiši {algorithm} u komentaru u istoj ili prethodnoj liniji ili u doc komentaru "
                        "funkcije" + (f", {extra}." if extra else "."))
                continue
            if (
                in_test
                or in_table
                or opcode
                or value in ALLOWED_NUMBERS
                or is_shift_amount(code, start)
                or is_radix(value, code, start, end)
                or is_mask(literal, value, code, start, end)
                or is_named_constant(code, top_consts)
            ):
                continue
            add(line_no, "magic-number",
                f"broj {literal} van imenovane konstante",
                "Broj bez imena ne kaže šta znači, a kad se ponavlja, izmena na jednom mestu ne stiže do ostalih.",
                "Uvedi const sa imenom koje kaže šta broj znači, ili dodaj \"// smell-ok: <razlog>\" "
                "ako je značenje očigledno na tom mestu.")

        if line.comment is not None:
            comment = line.comment
            if BANNER.search(comment):
                add(line_no, "banner", "baner komentar",
                    "Linija ponovljenih znakova deli fajl vizuelno i ne nosi informaciju; u Zig-u delove "
                    "odvajaju deklaracije i doc komentari.",
                    "Obriši liniju ili je zameni doc komentarom koji kaže šta sledi.")
            for pattern, word, suggestion in AI_PHRASES:
                if pattern.search(comment):
                    add(line_no, "ai-vocabulary", f"\"{word}\" u komentaru",
                        f"\"{word}\" je opšta reč česta u generisanom tekstu i ne kaže ništa konkretno o kodu.",
                        suggestion)
            if EMOJI.search(comment):
                add(line_no, "ai-vocabulary", "emodži u komentaru",
                    "Emodži u komentaru koda ne nosi informaciju i čest je u generisanom tekstu.",
                    "Obriši emodži; ako označava stanje, napiši ga rečima.")
            todo = TODO.search(comment)
            if todo and len(WORD.findall(todo["rest"])) < MIN_EXPLANATION_WORDS:
                add(line_no, "todo", f"{todo.group(1)} bez objašnjenja",
                    "Bez opisa se ne zna šta treba uraditi ni zašto nije urađeno.",
                    f"Napiši šta nedostaje i zašto, npr. \"{todo.group(1)}: macros, needed for ZEXDOC\", "
                    "ili otvori issue i navedi ga.")

        if UNREACHABLE.search(code):
            previous_comment = previous.comment if previous.code.strip() == "" else None
            if not explained(line.comment) and not explained(previous_comment):
                add(line_no, "unreachable", "unreachable bez objašnjenja",
                    "unreachable tvrdi da se grana ne može dostići; ako tvrdnja ne važi, u ReleaseFast je to "
                    "nedefinisano ponašanje, pa čitalac treba da zna na čemu počiva.",
                    "Dodaj komentar u istoj ili prethodnoj liniji koji kaže zašto je grana nedostižna, ili "
                    "zameni unreachable greškom ili iscrpnim switch-em.")

        # Braces, functions and test blocks.
        fn = FN_DECL.search(code)
        if fn and not code.rstrip().endswith(";"):
            doc = []
            j = index - 1
            while j >= 0 and lines[j].doc and not lines[j].code.strip():
                doc.append(lines[j].comment)
                j -= 1
            pending_fn = (fn.group(1), line_no, depth_before, " ".join(reversed(doc)))
        depth += code.count("{") - code.count("}")
        if pending_fn and pending_fn[1] == line_no and "{" in code and depth <= pending_fn[2]:
            pending_fn = None  # the whole function is on this line
        if pending_fn and depth > pending_fn[2]:
            name, fn_line, fn_depth, doc = pending_fn
            functions.append(
                {"name": name, "line": fn_line, "depth": fn_depth, "doc": doc, "code": 0, "comments": 0, "first": True}
            )
            pending_fn = None
        for f in functions:
            if f["first"]:
                continue  # the signature line is not part of the body
            if code.strip():
                f["code"] += 1
            elif line.comment is not None:
                f["comments"] += 1
        for f in functions:
            f["first"] = False
        while functions and depth <= functions[-1]["depth"]:
            f = functions.pop()
            f["code"] -= 1  # the closing brace
            body = f["code"] + f["comments"]
            if body >= MIN_FUNCTION_LINES and f["comments"] / body > MAX_COMMENT_RATIO:
                add(f["line"], "comment-ratio",
                    f"funkcija {f['name']}: {round(100 * f['comments'] / body)}% linija tela su komentari "
                    f"(granica {round(100 * MAX_COMMENT_RATIO)}%)",
                    "Kad komentari čine velik deo tela, obično prepričavaju kod umesto da objasne zašto.",
                    "Zadrži komentare koji objašnjavaju razlog; opis koraka prebaci u imena ili u doc komentar "
                    "funkcije.")
        while test_depths and depth <= test_depths[-1]:
            test_depths.pop()
        if table_depth is not None and depth <= table_depth:
            table_depth = None

    # Suppressions, per line.
    ok_lines = {}
    for index, line in enumerate(lines):
        m = SMELL_OK.search(line.comment or "")
        if m:
            ok_lines[index + 1] = m["reason"].strip()
    kept = [f for f in findings if not ok_lines.get(f.line)]
    for line_no, reason in ok_lines.items():
        if not reason:
            kept.append(Finding(path, line_no, "smell-ok", "smell-ok bez razloga",
                                "Izuzetak bez razloga ne kaže zašto pravilo ovde ne važi, pa se ne prihvata.",
                                "Napiši razlog: \"// smell-ok: <razlog>\"."))
    return sorted(kept, key=lambda f: f.line)


def zig_files(paths: list[str]) -> list[Path]:
    files = []
    for p in map(Path, paths):
        if p.is_dir():
            files += [f for f in sorted(p.rglob("*.zig")) if not SKIPPED_DIRS & set(f.parts)]
        elif p.is_file():
            files.append(p)
        else:
            sys.exit(f"smell_check: no such file or directory: {p}")
    return files


def main(argv: list[str]) -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    findings = []
    for f in zig_files(argv or DEFAULT_PATHS):
        findings += check_text(f.as_posix(), f.read_text(encoding="utf-8"))
    for finding in findings:
        print(finding.format())
    print(f"{len(findings)} nalaza" if findings else "bez nalaza")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
