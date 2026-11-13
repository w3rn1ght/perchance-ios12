from pathlib import Path

base = Path("perchance-client")
info_path = base / "Resources" / "Info.plist"
control_path = base / "control"

info = info_path.read_text(encoding="utf-8")
info = info.replace("<string>1.0.16</string>", "<string>1.1.0</string>")
info = info.replace("<string>16</string>", "<string>17</string>")
info_path.write_text(info, encoding="utf-8", newline="\n")

control = control_path.read_text(encoding="utf-8")
control = control.replace("Version: 1.0.16", "Version: 1.1.0")
control_path.write_text(control, encoding="utf-8", newline="\n")

import plistlib

parsed = plistlib.loads(info_path.read_bytes())
print("info:", parsed["CFBundleShortVersionString"], parsed["CFBundleVersion"])
print("control:", [line for line in control.splitlines() if line.startswith("Version")])
