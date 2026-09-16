#!/usr/bin/env python3
"""Собирает tvorez.lua: вшивает PNG из src/assets в src/tvorez.src.lua.

Запуск из корня репозитория: python3 src/build.py
"""
import base64
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ["banner.png", "banner@2x.png", "arrow.png", "check.png"]

source = (ROOT / "src" / "tvorez.src.lua").read_text(encoding="utf-8")
parts = ["ASSETS = {"]
for name in ASSETS:
    data = base64.encodebytes((ROOT / "src" / "assets" / name).read_bytes()).decode()
    parts.append(f'  ["{name}"] = [[\n{data}]],')
parts.append("}")

(ROOT / "tvorez.lua").write_text(source.replace("--@@ASSETS@@", "\n".join(parts)), encoding="utf-8")
print("tvorez.lua собран")
