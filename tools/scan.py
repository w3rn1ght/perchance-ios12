import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
patterns = [
    r"new Function\(",
    r"\beval\(",
    r"innerHTML\s*=",
    r"appendChild\(",
    r"createElement\(\s*['\"]script",
    r"document\.write",
    r"textContent\s*=",
]
for pat in patterns:
    matches = list(re.finditer(pat, text))
    print(f"{pat}: {len(matches)}")

for match in list(re.finditer(r"new Function\(", text))[:3]:
    print("---")
    print(text[max(0, match.start() - 250):match.start() + 350].replace("\n", " "))
