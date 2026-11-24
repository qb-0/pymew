<p align="center"><img src="assets/logo.png" alt="pymew" width="220"></p>
<h3 align="center">A cross-platform Python memory manipulation and overlay library designed to simplify the development of external game cheats</h3>

<p align="center">
  <a href="https://discord.gg/B34S4aMYqY"><img alt="Discord" src="https://img.shields.io/discord/949027922436575312?label=discord&logo=discord&logoColor=white&style=flat-square&color=5865F2"></a>
  <a href="CHEATSHEET.md"><img alt="Cheatsheet" src="https://img.shields.io/badge/docs-cheatsheet-FF6B35?style=flat-square"></a>
  <img alt="Python 3.7 to 3.14" src="https://img.shields.io/badge/python-3.7%20%E2%80%93%203.14-3776AB?style=flat-square&logo=python&logoColor=white">
  <img alt="Windows and Linux" src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux-4B5563?style=flat-square">
</p>

<p align="center">
  <img alt="MIT license" src="https://img.shields.io/badge/license-MIT-22C55E?style=flat-square">
  <img alt="AI assisted" src="https://img.shields.io/badge/AI--assisted-8B5CF6?style=flat-square">
  <a href="https://www.buymeabeer.com/quebee"><img alt="Buy me a beer" src="https://img.shields.io/badge/buy%20me%20a%20beer-0D0C22?style=flat-square&logo=buymeacoffee&logoColor=FFDD00"></a>
</p>

## Cheatsheet / Features

An overview of the full API can be found in the **[cheatsheet](CHEATSHEET.md)** — memory, overlay, drawing, input, hotkeys and more...

## Installation

```bash
pip install pymew
```

Requires 64-bit Python 3.7 or newer.

## Quick start

```python
import pymew as pm

with pm.mem.open("game.exe") as process:
    with pm.overlay.open(target="game.exe", exit_key="end") as overlay:
        address = process.base() + 0x2A0

        while overlay.loop():
            health = process.read(address, pm.mem.i32)
            pm.draw.text(text=f"health: {health}", x=20, y=20, size=20)
```

## Compiling from source

Install [Nim](https://nim-lang.org/install.html) and Git, then:

```bash
git clone https://github.com/qb-0/pymew
cd pymew
nimble install --depsOnly -y
nim c pymew
```

## Projects
<div align="center"><sub>Want your project listed here? Open a pull request or post it on pymew's discord server.</sub></div><br>

<div align="center"><a href="https://github.com/qb-0/pymew-DS3-ESP"><strong>pymew-DS3-ESP</strong></a><br><sub>Nov 24, 2026 · <a href="https://github.com/qb-0">qb-0</a></sub><br><a href="https://github.com/qb-0/pymew-DS3-ESP"><img src="https://raw.githubusercontent.com/qb-0/pymew-DS3-ESP/master/assets/ds3.png" width="340" alt="Darksiders III ESP"></a><br>A configurable, cross-platform Darksiders III ESP.</div><br>

<!--
Copy this block to add a project:

<div align="center"><a href="LINK"><strong>NAME</strong></a><br><sub>Mon DD, YYYY · <a href="https://github.com/AUTHOR">AUTHOR</a></sub><br><a href="LINK"><img src="SCREENSHOT" width="340" alt="NAME"></a><br>ONE LINE DESCRIPTION</div><br>
-->
