#!/usr/bin/env python3
"""Source rules for the C++ code of the simulation (verification/godot/c2/spec.md section 9.3, docs/godot-port-design.md
section 11: the rules for the C++ combat simulation).

    python3 -I tools/check_native_sources.py              check the sources; exit 0 if there is no violation
    python3 -I tools/check_native_sources.py --self-test  check the checker: every rule must flag its bad example and pass
                                                          its good example, and the comment/string stripping must work

The rules keep the simulation bit-exact and portable (the code must give the same numbers on x86_64, arm64 and
armv7, and match the original game's JavaScript). They are checked on the text of every C/C++ file below

    native/src/sim/          scope "sim"        plain C++17, no Godot
    native/third_party/      scope "third_party" the LGPL sin/cos, no Godot
    native/src/bindings/     scope "bindings"   the Godot glue: values are doubles and int64, never float32
    native/tests/            scope "tests"      the C++ test program

after comments and the contents of string and character literals have been blanked out (so a rule is not triggered by a
sentence in a comment). #include lines are checked on the text with the include path kept. This is a pattern check,
not a compiler: it cannot see an out-of-range conversion of a double to an integer (that is done by review and by the
golden vectors, which contain NaN, the infinities and out-of-range values), nor a compiler flag (native/SConstruct and
tools/build_native.sh check those).

Also checked: native/third_party/glibc_sincos/LICENSE is exactly the LGPL-2.1 text of V8's third_party/glibc/LICENSE and
native/LICENSES/V8-BSD-3-Clause.txt exactly V8's LICENSE (SHA-256 below).

tools/build_native.sh runs the self test and then the check before it builds. Needs Python 3.8 or newer (standard library only).
"""

import hashlib
import os
import re
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SOURCE_SUFFIXES = (".cpp", ".cc", ".cxx", ".c", ".h", ".hpp", ".hh", ".inc")

# scope -> directory below the repository (a file belongs to the first matching scope; sim and bindings are below src)
SCOPES = (
    ("sim", "native/src/sim"),
    ("bindings", "native/src/bindings"),
    ("third_party", "native/third_party"),
    ("tests", "native/tests"),
)

# The license texts that are copied from V8 (third_party/glibc/LICENSE and LICENSE of 14.1.146.11), by SHA-256.
LICENSE_FILES = (
    ("native/third_party/glibc_sincos/LICENSE", "b634ab5640e258563c536e658cad87080553df6f34f62269a21d554844e58bfe"),
    ("native/LICENSES/V8-BSD-3-Clause.txt", "6ab33af8774a0f396ee3aeeb761e3229057682d6f9fa7f572e390c2cb3a6e509"),
)

GODOT_FREE = ("sim", "third_party")
FLOAT32_GODOT_TYPES = (
    "Vector2|Vector3|Vector4|Quaternion|Basis|Transform2D|Transform3D|Projection|Plane|AABB|Rect2|Color"
    "|PackedFloat32Array|PackedVector2Array|PackedVector3Array|PackedVector4Array|PackedColorArray"
)


class Rule:
    """A pattern rule. kind "code": the pattern is searched in the text without comments and literal contents;
    kind "include": in the #include lines (comments removed, the path kept)."""

    def __init__(self, name, scopes, kind, pattern, message, bad, good):
        self.name = name
        self.scopes = scopes
        self.kind = kind
        self.regex = re.compile(pattern)
        self.message = message
        self.bad = bad
        self.good = good


def pragma_rule():
    return Rule(
        "no-pragma", ("sim", "third_party", "bindings", "tests"), "code", r"#\s*pragma\b(?!\s+once\b)|\b_Pragma\b|__attribute__\s*\(\(\s*optimize\b",
        "#pragma (other than once), _Pragma and the optimize attribute can change floating-point behavior",
        "#pragma clang fp contract(fast)\n", "#pragma once\n// #pragma STDC FP_CONTRACT ON\n",
    )


RULES = [
    Rule("no-float", ("sim", "third_party", "bindings", "tests"), "code", r"\bfloat\b",
         "float is 32 bits; the simulation uses double", "float x = 1.0f;\n", "double x = 1.0; // a float in a comment\nconst char *s = \"float\";\n"),
    Rule("no-long", ("sim", "third_party"), "code", r"\blong\b",
         "long (long long, long double) has no fixed size (32 bits on armv7); use <cstdint> types", "long x = 1;\n", "int64_t x = 1; // a long time\nconst char *s = \"long\";\n"),
    Rule("no-long-double", ("tests",), "code", r"\blong\s+double\b",
         "long double is not IEEE binary64 on x86", "long double x = 1;\n", "double x = 1; // long double\nint64_t y = 2;\n"),
    Rule("no-real-t", ("sim", "third_party", "bindings"), "code", r"\breal_t\b",
         "real_t is float32 in the Godot build", "real_t x = 1;\n", "double x = 1; // real_t\n"),
    Rule("no-float32-godot-types", ("bindings",), "code", r"\b(?:%s)\b" % FLOAT32_GODOT_TYPES,
         "Vector2/Vector3/... hold float32 values; pass doubles and PackedFloat64Array", "godot::Vector2 v;\n", "godot::Vector2i v; // a Vector2\ngodot::PackedFloat64Array a;\n"),
    Rule("no-std-sort", GODOT_FREE, "code", r"\bstd\s*::\s*sort\b",
         "std::sort is not stable and differs between standard libraries; use a stable sort", "std::sort(v.begin(), v.end());\n", "std::stable_sort(v.begin(), v.end());\n// std::sort\n"),
    Rule("no-unordered", GODOT_FREE, "code", r"unordered_",
         "iterating unordered containers gives an implementation-defined order", "std::unordered_map<int, int> m;\n", "std::map<int, int> m; // unordered_map\n"),
    Rule("no-random-header", GODOT_FREE, "include", r"#\s*include\s*[<\"]random[>\"]",
         "<random> distributions differ between standard libraries", "#include <random>\n", "#include <cstdint> // <random>\n"),
    Rule("no-threads", GODOT_FREE, "include", r"#\s*include\s*[<\"](?:thread|mutex|atomic|future|condition_variable|shared_mutex|semaphore|barrier|latch|stop_token)[>\"]",
         "the simulation is single-threaded and deterministic", "#include <thread>\n", "#include <cstdint>\n// #include <mutex>\n"),
    Rule("no-std-thread", GODOT_FREE, "code", r"\bstd\s*::\s*(?:thread|jthread|mutex|atomic|async)\b",
         "the simulation is single-threaded and deterministic", "std::thread t;\n", "int thread_count = 1; // std::thread\n"),
    Rule("no-fma", ("sim", "third_party", "tests"), "code", r"\bfma[fl]?\b|\b__builtin_fma\w*",
         "fma rounds once where the original game rounds twice", "double r = std::fma(a, b, c);\n", "double r = a * b + c; // fma\ndouble fmax_like = 1.0;\n"),
    pragma_rule(),
    Rule("no-time-header", GODOT_FREE, "include", r"#\s*include\s*[<\"](?:chrono|ctime|time\.h)[>\"]",
         "the simulation must not depend on the clock", "#include <chrono>\n", "#include <cstdint>\n// #include <ctime>\n"),
    Rule("no-godot-include", GODOT_FREE, "include", r"(?i)#\s*include\s*[<\"][^>\"]*(?:godot|swarm_native|register_types|build_info)[^>\"]*[>\"]",
         "native/src/sim and native/third_party are plain C++ without Godot headers", "#include <godot_cpp/godot.hpp>\n", "#include \"bits.h\"\n// #include <godot_cpp/godot.hpp>\n"),
    Rule("no-upward-include", ("third_party",), "include", r"#\s*include\s*[<\"][^>\"]*(?:sim/|bindings/)[^>\"]*[>\"]",
         "the third-party library must not depend on the code that uses it", "#include \"sim/js_math.h\"\n", "#include \"glibc_sincos.h\"\n"),
    Rule("no-bindings-include", ("sim",), "include", r"#\s*include\s*[<\"][^>\"]*bindings/[^>\"]*[>\"]",
         "the simulation must not depend on the Godot glue", "#include \"bindings/rng_binding.h\"\n", "#include \"js_math.h\"\n"),
]

# rand( srand( time( : the C library functions (a member such as GameRng::rand is fine: see check_c_library_calls)
C_LIBRARY_CALL = re.compile(r"(?<![\w.])((?:std\s*::\s*|::\s*)?)(srand|rand|time)\s*\(")
STATEMENT_WORDS = {"return", "else", "case", "do", "throw", "co_return", "co_yield", "new", "delete", "not", "and", "or", "if", "while", "for", "switch"}
C_LIBRARY_RULE = "no-c-library-time-random"
C_LIBRARY_SCOPES = GODOT_FREE
C_LIBRARY_MESSAGE = "rand(), srand() and time() give non-reproducible or platform-dependent numbers"
C_LIBRARY_BAD = "int r = rand();\nreturn std::time(nullptr);\n"
C_LIBRARY_GOOD = "double rand(double a, double b) { return a; }\nauto v = rng.rand(1.0, 2.0);\nauto w = ptr->rand(1.0, 2.0);\n// rand(\n"


def strip_comments(text):
    """Comments replaced by spaces (newlines kept, so line numbers stay); the contents of string and character literals
    are kept. Returns (text, error); error is a message for constructs this checker does not understand."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        two = text[i:i + 2]
        if two == "//":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
        elif two == "/*":
            end = text.find("*/", i + 2)
            if end < 0:
                return None, "unterminated comment"
            for ch in text[i:end + 2]:
                out.append("\n" if ch == "\n" else " ")
            i = end + 2
        elif c == '"' and i > 0 and text[i - 1] == "R":
            return None, 'raw string literals (R"...") are not supported by this checker'
        elif c == '"' or (c == "'" and not (i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_"))):
            quote = c
            out.append(c)
            i += 1
            while i < n and text[i] != quote:
                if text[i] == "\n":
                    return None, "unterminated string or character literal"
                if text[i] == "\\" and i + 1 < n:
                    out.append(text[i])
                    i += 1
                out.append(text[i])
                i += 1
            if i >= n:
                return None, "unterminated string or character literal"
            out.append(quote)
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out), None


def blank_literals(text):
    """The text with the contents of string and character literals replaced by spaces (the quotes stay). The input must
    already be free of comments."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"' or (c == "'" and not (i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_"))):
            quote = c
            out.append(c)
            i += 1
            while i < n and text[i] != quote:
                if text[i] == "\\" and i + 1 < n:
                    out.append(" ")
                    i += 1
                out.append(" ")
                i += 1
            out.append(quote)
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def check_c_library_calls(code):
    """Offsets of calls of the C library's rand, srand and time (declarations and member calls are not calls of it)."""
    hits = []
    for m in C_LIBRARY_CALL.finditer(code):
        before = code[:m.start()].rstrip()
        if before.endswith("->"):
            continue  # a member call through a pointer
        if not m.group(1).strip():
            previous = re.search(r"([A-Za-z_]\w*)$", before)
            if previous and previous.group(1) not in STATEMENT_WORDS:
                continue  # `double rand(double a, double b)`: a declaration or definition (the name follows a type)
        hits.append(m.start())
    return hits


def check_text(scope, text):
    """Findings [(line, rule name, message)] of the rules of `scope` for one file's text, or [(0, "lexer", message)]."""
    without_comments, error = strip_comments(text)
    if error:
        return [(0, "lexer", error)]
    code = blank_literals(without_comments)
    findings = []
    for rule in RULES:
        if scope not in rule.scopes:
            continue
        haystack = without_comments if rule.kind == "include" else code
        for m in rule.regex.finditer(haystack):
            findings.append((line_of(haystack, m.start()), rule.name, rule.message))
    if scope in C_LIBRARY_SCOPES:
        for start in check_c_library_calls(code):
            findings.append((line_of(code, start), C_LIBRARY_RULE, C_LIBRARY_MESSAGE))
    findings.sort()
    return findings


def scope_of(relative):
    for scope, directory in SCOPES:
        if relative == directory or relative.startswith(directory + "/"):
            return scope
    return None


def source_files(root):
    found = []
    for scope, directory in SCOPES:
        base = os.path.join(root, directory)
        for current, subdirectories, names in os.walk(base):
            subdirectories.sort()
            for name in sorted(names):
                if name.endswith(SOURCE_SUFFIXES):
                    path = os.path.join(current, name)
                    found.append((scope, os.path.relpath(path, root).replace(os.sep, "/")))
    return found


def check_license_files(root):
    problems = []
    for relative, expected in LICENSE_FILES:
        path = os.path.join(root, relative)
        try:
            with open(path, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
        except OSError as error:
            problems.append("%s: cannot be read (%s)" % (relative, error))
            continue
        if digest != expected:
            problems.append("%s: SHA-256 is %s, expected %s (it must be the exact copy of V8's file)" % (relative, digest, expected))
    return problems


def check_tree(root):
    """Returns (number of files, list of violation strings)."""
    violations = []
    files = source_files(root)
    for scope, relative in files:
        try:
            with open(os.path.join(root, relative), encoding="utf-8") as f:
                text = f.read()
        except (OSError, UnicodeDecodeError) as error:
            violations.append("%s: cannot be read as UTF-8 text (%s)" % (relative, error))
            continue
        for line, rule, message in check_text(scope, text):
            where = "%s:%d" % (relative, line) if line else relative
            source_line = text.split("\n")[line - 1].strip() if line else ""
            violations.append("%s: [%s] %s%s" % (where, rule, message, ("\n    " + source_line) if source_line else ""))
    violations.extend(check_license_files(root))
    return len(files), violations


# ---- Self test ------------------------------------------------------------------------------------------------------

def self_test():
    failures = []

    def expect(condition, text):
        if not condition:
            failures.append(text)

    names = set()
    for rule in RULES:
        if rule.name in names:
            failures.append("rule %s is defined twice" % rule.name)
        names.add(rule.name)
        for scope, _ in SCOPES:
            bad = [f for f in check_text(scope, rule.bad) if f[1] == rule.name]
            good = [f for f in check_text(scope, rule.good) if f[1] == rule.name]
            if scope in rule.scopes:
                expect(bad, "%s: the bad example %r is not flagged in scope %s" % (rule.name, rule.bad, scope))
            else:
                expect(not bad, "%s: flagged in scope %s, which is not its scope" % (rule.name, scope))
            expect(not good, "%s: the good example %r is flagged in scope %s: %s" % (rule.name, rule.good, scope, good))
    for scope in C_LIBRARY_SCOPES:
        expect([f for f in check_text(scope, C_LIBRARY_BAD) if f[1] == C_LIBRARY_RULE], "%s: the bad example is not flagged in scope %s" % (C_LIBRARY_RULE, scope))
        expect(not [f for f in check_text(scope, C_LIBRARY_GOOD) if f[1] == C_LIBRARY_RULE], "%s: the good example is flagged in scope %s" % (C_LIBRARY_RULE, scope))
    for scope in ("bindings", "tests"):
        expect(not check_text(scope, C_LIBRARY_BAD) or all(f[1] != C_LIBRARY_RULE for f in check_text(scope, C_LIBRARY_BAD)), "%s: flagged in scope %s" % (C_LIBRARY_RULE, scope))
    # each rule of the table of spec 9.3 appears: float, long, real_t, std::sort, unordered_, <random>, threads, fma, pragma, clock, rand
    for needed in ("no-float", "no-long", "no-real-t", "no-std-sort", "no-unordered", "no-random-header", "no-threads", "no-fma", "no-pragma", "no-time-header", C_LIBRARY_RULE, "no-godot-include"):
        expect(needed in names or needed == C_LIBRARY_RULE, "the rule %s is missing" % needed)

    # the lexer: comments and literals do not trigger, code does; line numbers are kept
    expect(check_text("sim", "// float x;\n/* long\n   double */ int y;\nconst char *s = \"float\\\"long\";\nchar c = 'f';\n") == [], "comments and literals are not blanked correctly")
    expect([f[0] for f in check_text("sim", "int a;\n/* comment\n */\nfloat b;\n")] == [4], "the line number of a finding after a multi-line comment is wrong")
    expect(check_text("sim", "/* unterminated\nint a;\n")[0][1] == "lexer", "an unterminated comment is not reported")
    expect(check_text("sim", "const char *s = R\"(float)\";\n")[0][1] == "lexer", "a raw string literal is not reported")
    expect(check_text("sim", "int x = 1'000; float y;\n")[0][1] == "no-float", "a digit separator hides the rest of the line")
    expect([f[1] for f in check_text("sim", "#pragma once\n#pragma STDC FP_CONTRACT ON\n")] == ["no-pragma"], "#pragma once must pass and any other pragma fail")
    expect(not check_text("sim", "double a = 0x1.8p3; uint64_t b = UINT64_C(0x3FF0000000000000);\n"), "hex floats and UINT64_C are flagged")

    # the license check
    with tempfile.TemporaryDirectory() as directory:
        problems = check_license_files(directory)
        expect(len(problems) == len(LICENSE_FILES) and all("cannot be read" in p for p in problems), "missing license files are not reported")
        for relative, _ in LICENSE_FILES:
            os.makedirs(os.path.dirname(os.path.join(directory, relative)), exist_ok=True)
            with open(os.path.join(directory, relative), "w", encoding="utf-8") as f:
                f.write("not the license\n")
        problems = check_license_files(directory)
        expect(len(problems) == len(LICENSE_FILES) and all("SHA-256" in p for p in problems), "a changed license file is not reported")
        # a whole tree with one violation per scope is reported, a clean one passes
        for scope, relative_dir in SCOPES:
            os.makedirs(os.path.join(directory, relative_dir), exist_ok=True)
            with open(os.path.join(directory, relative_dir, "bad.cpp"), "w", encoding="utf-8") as f:
                f.write("float x;\n")
        count, violations = check_tree(directory)
        flagged = [v for v in violations if "[no-float]" in v]
        expect(count == len(SCOPES) and len(flagged) == len(SCOPES), "check_tree finds %d no-float violations in %d files" % (len(flagged), count))

    if failures:
        for text in failures:
            print("self-test FAILED: " + text, file=sys.stderr)
        print("check_native_sources: self-test failed (%d problem(s))" % len(failures), file=sys.stderr)
        return 1
    print("check_native_sources: self-test OK (%d rules + the C library rule, the lexer and the license check)" % len(RULES))
    return 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if argv:
        print("usage: python3 -I tools/check_native_sources.py [--self-test]", file=sys.stderr)
        return 2
    count, violations = check_tree(REPO_ROOT)
    if count == 0:
        print("check_native_sources: no source files found below native/src/sim, bindings, third_party and tests", file=sys.stderr)
        return 1
    if violations:
        for v in violations:
            print(v, file=sys.stderr)
        print("check_native_sources: %d violation(s) in %d files" % (len(violations), count), file=sys.stderr)
        return 1
    print("check_native_sources: %d files checked, no violations; the LGPL and BSD license texts are the exact V8 copies" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
