import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
print("Function(:", len(re.findall(r"Function\(", text)))
print("new Function:", len(re.findall(r"new\s+Function", text)))

for index, match in enumerate(re.finditer(r"""createElement\(\s*["']script""", text)):
    if index >= 4:
        break
    print("---")
    print(text[max(0, match.start() - 300):match.start() + 300].replace("\n", " "))

print("=== textContent assignments with script-like vars ===")
count = 0
for match in re.finditer(r"textContent\s*=", text):
    chunk = text[max(0, match.start() - 120):match.start() + 160].replace("\n", " ")
    if "script" in chunk.lower():
        print("---")
        print(chunk)
        count += 1
        if count >= 5:
            break
