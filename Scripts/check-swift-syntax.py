#!/usr/bin/env python3
"""Offline grammar check only. Does not compile/type-check Swift or run XCTest.

Requires tree-sitter==0.26.0 and tree-sitter-swift==0.7.3.
Known grammar limitations are compared with the specified immutable base.
"""
import argparse
from pathlib import Path
import subprocess
import sys

import tree_sitter_swift
from tree_sitter import Language, Parser

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--base", default="4b8c359807414efda4e8b82cc4321ea4738b8ae6")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
syntax = Parser(Language(tree_sitter_swift.language()))


def errors(data):
    result = []
    pending = [syntax.parse(data).root_node]
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            result.append((node.type, node.start_point, node.end_point, node.text))
        pending.extend(node.children)
    return result


files = sorted(list((root / "MeetingFlowAI").rglob("*.swift"))
               + list((root / "MeetingFlowAITests").rglob("*.swift")))
failed = []
limitations = []
for path in files:
    relative = path.relative_to(root).as_posix()
    current_errors = errors(path.read_bytes())
    if not current_errors:
        continue
    base = subprocess.run(["git", "show", f"{args.base}:{relative}"], cwd=root,
                          capture_output=True, check=False)
    if base.returncode == 0 and current_errors == errors(base.stdout):
        limitations.append(relative)
    else:
        failed.append(relative)
        for kind, start, end, _ in current_errors:
            print(f"ERROR {relative}:{start.row + 1}:{start.column + 1}: {kind}")
for path in limitations:
    print(f"BASELINE GRAMMAR LIMITATION (unchanged): {path}")
print(f"Checked {len(files)} Swift files; {len(failed)} new syntax-error files; "
      f"{len(limitations)} unchanged baseline grammar limitations.")
print("This is not Swift compiler or XCTest validation.")
sys.exit(bool(failed))
