import sys, pathlib

import tree_sitter_swift as tss
from tree_sitter import Language, Parser

lang = Language(tss.language())
parser = Parser(lang)

root = pathlib.Path(sys.argv[1])
files = sorted(root.rglob("*.swift"))
bad = 0
total_lines = 0
for path in files:
    data = path.read_bytes()
    tree = parser.parse(data)
    total_lines += data.count(b"\n") + (0 if data.endswith(b"\n") else 1)
    errors = []
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append(node)
        else:
            stack.extend(node.children)
    if errors:
        bad += 1
        print(f"FAIL  {path.relative_to(root)}")
        for node in errors[:6]:
            text = data[node.start_byte:node.end_byte].decode("utf-8", "replace").splitlines()
            snippet = " / ".join(t.strip() for t in text[:2])[:180]
            print(f"        line {node.start_point[0] + 1}: {node.type}: {snippet}")
    else:
        print(f"OK    {path.relative_to(root)}  ({data.count(bytes([10])) + 1} lines)")

print(f"\nfiles={len(files)}  syntax_failures={bad}  total_lines={total_lines}")
print("note: this is a tree-sitter SYNTAX check only; it verifies bracket balance")
print("note: and parse structure, NOT undefined symbols or type errors. Run")
print("note: `xcrun swiftc -typecheck` or xcodebuild for semantic verification.")
sys.exit(1 if bad else 0)
