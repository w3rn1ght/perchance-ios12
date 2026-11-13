import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
urls = sorted(set(re.findall(r"""["'](/[A-Za-z0-9_./-]+\.js)["']""", text)))
print("js urls:", urls[:40])

for match in list(re.finditer(r"""createElement\(\s*["']script""", text)):
    print("---")
    print(text[max(0, match.start() - 400):match.start() + 300].replace("\n", " "))
