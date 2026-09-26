"""The reference assemblers. Each one's path comes from a command-line option
or an environment variable, and its version is checked, since another
version may encode or accept things differently."""

import os
import subprocess
import sys
from dataclasses import dataclass


@dataclass
class Tool:
    option: str
    env: str
    version: str
    version_args: list
    # Text of the version output that identifies that version.
    banner: str


SJASMPLUS = Tool("sjasmplus", "SJASMPLUS", "1.24.0", ["--version"], "v1.24.0")
# The release build of 2.4 prints its build number, commit and date.
Z88DK_Z80ASM = Tool("z88dk-z80asm", "Z88DK_Z80ASM", "2.4", [], "23854-4d530b6eb7-20251002")


def add_option(parser, tool):
    parser.add_argument("--" + tool.option, metavar="PATH", default=os.environ.get(tool.env),
                        help="%s %s executable (default: $%s)" % (tool.option, tool.version, tool.env))


def path(parser, args, tool):
    """The tool's path from the parsed arguments, once its version is right."""
    exe = getattr(args, tool.option.replace("-", "_"))
    if not exe:
        parser.error("give --%s PATH or set %s" % (tool.option, tool.env))
    r = subprocess.run([exe] + tool.version_args, capture_output=True, text=True)
    if tool.banner not in r.stdout + r.stderr:
        sys.exit("%s is not %s %s" % (exe, tool.option, tool.version))
    return exe
