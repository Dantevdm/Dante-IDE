"""Generates the Dante design canvas: one HTML artboard per screen, in all three themes.

    python3 design/generate_screens.py

Writes design/screens/*.dc.html and canvas.json (the canvas layout). Published at
https://claude.ai/artifact/KFxwBAj14jL7w1MHNcc5Pi
"""
import json, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "screens")

# ---------- themes ----------
THEMES = {
    "dark": dict(
        BG="#0B0D10", PANEL="#0F1216", CARD="#12161B", RAISED="#171C22", LINE="#1E242C", LINE2="#2A313B",
        TX="#E8EBEF", TX2="#A3ACB8", TX3="#7D8794", ACC="#8FA8FF", ACC_BG="#1A2238", ACC_LINE="#2B3760", ACC_HOVER="#B7C6FF",
        ON_ACC="#0B0D10", AMB="#F2B061", GRN="#5AD69A", RED="#FF7A7A", GRN_BG="#173326", WARN_BG="#1F1A12",
        WARN_LINE="#3A2E1A", WARN_BORDER="#5A4520", CODE_BG="#0D1014", LN="#4F5864", LN_ACT="#9AA3AF", DOT="#1C2129",
        DONE="#3D4A6B", TRACK="#262C35", SHADOW="0 6px 18px rgba(0, 0, 0, 0.35)", SHADOW_L="0 12px 32px rgba(0, 0, 0, 0.5)",
        ARROW="#4A5566", ADD_BG="rgba(90, 214, 154, 0.07)", DEL_BG="rgba(255, 122, 122, 0.07)", HL="rgba(143, 168, 255, 0.06)",
        K="#C3A6FF", S="#9BD5A8", F="#8FA8FF", T="#7FD1E0", C="#76808C", N="#F2B061", SCRIM="rgba(5, 6, 8, 0.62)", LOGT="#5C6570",
        BAR=["#3D4A6B", "#8FA8FF", "#6C7FC0", "#B7C6FF", "#4E5F96", "#8796C9"], NAME="Dark"),
    "light": dict(
        BG="#F5F6F8", PANEL="#ECEEF2", CARD="#FFFFFF", RAISED="#F4F5F8", LINE="#E1E4EA", LINE2="#CDD3DC",
        TX="#12151A", TX2="#474F5B", TX3="#5F6875", ACC="#3B5BDB", ACC_BG="#E8EDFF", ACC_LINE="#C3CFFB", ACC_HOVER="#2A47B8",
        ON_ACC="#FFFFFF", AMB="#9A5A00", GRN="#1D7F4E", RED="#C2362F", GRN_BG="#DDF3E7", WARN_BG="#FDF3E2",
        WARN_LINE="#F0D7A8", WARN_BORDER="#E2B868", CODE_BG="#FBFBFD", LN="#A3AAB4", LN_ACT="#474F5B", DOT="#DADEE5",
        DONE="#A9B6E6", TRACK="#E1E4EA", SHADOW="0 4px 14px rgba(20, 24, 32, 0.08)", SHADOW_L="0 16px 40px rgba(20, 24, 32, 0.16)",
        ARROW="#9AA3AF", ADD_BG="rgba(29, 127, 78, 0.08)", DEL_BG="rgba(194, 54, 47, 0.07)", HL="rgba(59, 91, 219, 0.06)",
        K="#7C3AED", S="#1D7F4E", F="#3B5BDB", T="#0E7490", C="#6B7480", N="#9A5A00", SCRIM="rgba(20, 24, 32, 0.25)", LOGT="#8A929D",
        BAR=["#A9B6E6", "#3B5BDB", "#6C82E0", "#24398F", "#8FA0E6", "#5068C9"], NAME="Light"),
    "paper": dict(
        BG="#F3EEE4", PANEL="#EBE4D7", CARD="#FAF7F0", RAISED="#F0EADF", LINE="#E0D6C5", LINE2="#CFC3AE",
        TX="#221D16", TX2="#4D4539", TX3="#6B6152", ACC="#2C4C9C", ACC_BG="#E3E4EC", ACC_LINE="#C2C8DD", ACC_HOVER="#1F3A7D",
        ON_ACC="#FAF7F0", AMB="#8F530E", GRN="#2C7148", RED="#A8382B", GRN_BG="#DCEADD", WARN_BG="#F6E9D2",
        WARN_LINE="#E6CFA3", WARN_BORDER="#D7B176", CODE_BG="#F6F1E7", LN="#ADA392", LN_ACT="#4D4539", DOT="#E2D9C9",
        DONE="#AEB7D2", TRACK="#E0D6C5", SHADOW="0 3px 10px rgba(60, 45, 20, 0.08)", SHADOW_L="0 16px 40px rgba(60, 45, 20, 0.16)",
        ARROW="#A0937D", ADD_BG="rgba(44, 113, 72, 0.08)", DEL_BG="rgba(168, 56, 43, 0.07)", HL="rgba(44, 76, 156, 0.06)",
        K="#6D3FB5", S="#2C7148", F="#2C4C9C", T="#1F6A78", C="#7A705F", N="#8F530E", SCRIM="rgba(60, 45, 20, 0.2)", LOGT="#8C8270",
        BAR=["#AEB7D2", "#2C4C9C", "#5B72B3", "#1B2F63", "#8696C4", "#40589F"], NAME="Paper"),
}

def set_theme(name):
    globals().update(THEMES[name])
    globals()["THEME"] = name

set_theme("dark")

MONO = "'Geist Mono', ui-monospace, 'SF Mono', Menlo, monospace"
SERIF = "'Newsreader', 'Iowan Old Style', Georgia, serif"
SANS = "'Geist', -apple-system, 'Helvetica Neue', system-ui, sans-serif"

def font_link(serif=False):
    fam = "family=Geist:wght@400;500;600;700&amp;family=Geist+Mono:wght@400;500;600"
    if serif:
        fam += "&amp;family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,500;0,6..72,600;1,6..72,400"
    return f'<link rel="stylesheet" href="https://fonts.googleapis.com/css2?{fam}&amp;display=swap">'

def base_css():
    return (f"body{{margin:0;background:{BG};color:{TX};font-family:{SANS};"
            f"font-size:13px;line-height:1.45;-webkit-font-smoothing:antialiased}}"
            f"a{{color:{ACC};text-decoration:none}}a:hover{{color:{ACC_HOVER}}}"
            "button{font:inherit;cursor:pointer}")

ICONS = {
    "home": '<path d="M3 10.5 12 3l9 7.5V21h-6v-6H9v6H3z"/>',
    "plan": '<path d="M10 6h10M10 12h10M10 18h10"/><path d="m4 6 1.2 1.2L7.5 5M4 12l1.2 1.2L7.5 11M4 18l1.2 1.2L7.5 17"/>',
    "diagram": '<rect x="3" y="3" width="7" height="5" rx="1"/><rect x="14" y="16" width="7" height="5" rx="1"/><rect x="3" y="16" width="7" height="5" rx="1"/><path d="M6.5 8v8M6.5 12h11v4"/>',
    "code": '<path d="m8 7-5 5 5 5M16 7l5 5-5 5M14 4l-4 16"/>',
    "flask": '<path d="M9 3h6M10 3v6l-5 9a2 2 0 0 0 1.8 3h10.4a2 2 0 0 0 1.8-3l-5-9V3"/><path d="M7.5 15h9"/>',
    "box": '<path d="M12 3 21 7.5v9L12 21 3 16.5v-9z"/><path d="M3 7.5 12 12l9-4.5M12 12v9"/>',
    "book": '<path d="M5 4h11a3 3 0 0 1 3 3v13H8a3 3 0 0 1-3-3z"/><path d="M5 17a3 3 0 0 1 3-3h11"/>',
    "chat": '<path d="M4 5h16v11H9l-5 4z"/><path d="M8.5 10.5h.01M12 10.5h.01M15.5 10.5h.01"/>',
    "search": '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    "branch": '<circle cx="6" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><circle cx="18" cy="7" r="2"/><path d="M6 7v10M18 9a6 6 0 0 1-6 6H8"/>',
    "check": '<path d="m5 12 5 5 9-10"/>',
    "term": '<path d="m5 8 4 4-4 4M12 16h7"/>',
    "play": '<path d="M7 5v14l11-7z"/>',
    "plus": '<path d="M12 5v14M5 12h14"/>',
    "folder": '<path d="M3 6a1 1 0 0 1 1-1h5l2 2h9a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z"/>',
    "file": '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4"/>',
    "chev": '<path d="m9 6 6 6-6 6"/>',
    "chevd": '<path d="m6 9 6 6 6-6"/>',
    "clone": '<circle cx="6" cy="6" r="2"/><circle cx="6" cy="18" r="2"/><circle cx="18" cy="12" r="2"/><path d="M6 8v8M8 6h4a4 4 0 0 1 4 4v0"/>',
    "refresh": '<path d="M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7"/>',
    "send": '<path d="M5 12h14M13 6l6 6-6 6"/>',
    "alert": '<path d="M12 4 2.5 20h19z"/><path d="M12 10v4M12 17h.01"/>',
    "link": '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
    "layers": '<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/>',
    "doc": '<path d="M6 3h12v18H6z"/><path d="M9 8h6M9 12h6M9 16h4"/>',
    "stop": '<rect x="6" y="6" width="12" height="12" rx="1"/>',
    "shell": '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M12 15h5"/>',
    "sliders": '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
    "rocket": '<path d="M5 15c-1.5 1.5-2 5-2 5s3.5-.5 5-2M9 15l-3-3c1-4 5-9 13-9 0 8-5 12-9 13z"/><circle cx="15" cy="9" r="1.5"/>',
    "pulse": '<path d="M3 12h4l3-7 4 14 3-7h4"/>',
    "db": '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    "flow": '<circle cx="5" cy="6" r="2"/><circle cx="19" cy="18" r="2"/><path d="M7 6h7a3 3 0 0 1 0 6h-4a3 3 0 0 0 0 6h7"/>',
    "cloud": '<path d="M7 18h10a4 4 0 0 0 .5-8A6 6 0 0 0 6 9a4.5 4.5 0 0 0 1 9z"/>',
    "tag": '<path d="M3 12V4h8l10 10-8 8z"/><circle cx="7.5" cy="8.5" r="1.5"/>',
    "sun": '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    "moon": '<path d="M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5z"/>',
    "paper": '<path d="M6 3h9l3 3v15H6z"/><path d="M9 9h6M9 13h6M9 17h3"/>',
    "shield": '<path d="M12 3 4 6v6c0 5 3.5 8 8 9 4.5-1 8-4 8-9V6z"/><path d="m9 12 2 2 4-4"/>',
    "sparkle": '<path d="M12 4v4M12 16v4M4 12h4M16 12h4"/>',
    "export": '<path d="M12 3v12M7 8l5-5 5 5"/><path d="M5 14v6h14v-6"/>',
    "x": '<path d="M6 6l12 12M18 6 6 18"/>',
    "kbd": '<rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 10h.01M11 10h.01M15 10h.01M7 14h10"/>',
}

def ic(name, size=16, color="currentColor", sw=1.75):
    return (f'<svg aria-hidden="true" width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="{color}" '
            f'stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round" style="flex: 0 0 auto">{ICONS[name]}</svg>')

def dot(color, size=8):
    return f'<span aria-hidden="true" style="width: {size}px; height: {size}px; border-radius: 50%; background: {color}; flex: 0 0 auto"></span>'

def chip(text, color=None, bg=None, border=None):
    color = color or TX2; bg = bg or RAISED; border = border or LINE
    return (f'<span style="display: inline-flex; align-items: center; gap: 6px; padding: 3px 8px; border-radius: 6px; background: {bg}; '
            f'border: 1px solid {border}; color: {color}; font-size: 12px; white-space: nowrap">{text}</span>')

def mono_chip(text, color=None):
    color = color or TX2
    return (f'<span style="display: inline-flex; align-items: center; padding: 2px 7px; border-radius: 5px; background: {RAISED}; '
            f'border: 1px solid {LINE}; color: {color}; font-family: {MONO}; font-size: 11.5px; white-space: nowrap">{text}</span>')

def eyebrow(text):
    return f'<div style="font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: {TX3}; font-weight: 500">{text}</div>'

def card(inner, extra=""):
    return (f'<section style="background: {CARD}; border: 1px solid {LINE}; border-radius: 12px; padding: 18px 20px; box-sizing: border-box; '
            f'display: flex; flex-direction: column; gap: 14px; min-width: 0; {extra}">{inner}</section>')

def card_head(title, right=""):
    return (f'<div style="display: flex; justify-content: space-between; align-items: center; gap: 12px">'
            f'<h2 style="margin: 0; font-size: 13px; font-weight: 600; color: {TX}">{title}</h2>{right}</div>')

def btn(label, primary=False, icon=None, href=None):
    style = ("display: inline-flex; align-items: center; gap: 6px; min-height: 30px; padding: 0 12px; border-radius: 8px; font-size: 12.5px; font-weight: 500; white-space: nowrap; box-sizing: border-box; ")
    if primary:
        style += f"background: {ACC}; color: {ON_ACC}; border: 1px solid {ACC}"
    else:
        style += f"background: {RAISED}; color: {TX}; border: 1px solid {LINE2}"
    inner = (ic(icon, 14) if icon else "") + label
    if href:
        return f'<a href="{href}" style="{style}">{inner}</a>'
    return f'<button type="button" style="{style}">{inner}</button>'

def seg_group(label, items, on, pad="6px 12px"):
    out = "".join(
        f'<button type="button" aria-pressed="{"true" if it == on else "false"}" style="border: 0; padding: {pad}; border-radius: 6px; font-size: 12.5px; display: flex; align-items: center; gap: 6px; '
        + (f'background: {CARD}; color: {TX}; font-weight: 500; box-shadow: 0 0 0 1px {LINE2}' if it == on else f'background: transparent; color: {TX3}')
        + f'">{it}</button>' for it in items)
    return f'<div role="group" aria-label="{label}" style="display: flex; gap: 2px; padding: 3px; background: {PANEL}; border: 1px solid {LINE}; border-radius: 9px">{out}</div>'

PHASES = ["Discover", "Define", "Design", "Build", "Test", "Release", "Operate"]

def traffic():
    return ('<div aria-hidden="true" style="display: flex; gap: 8px; padding-right: 4px"><span style="width: 12px; height: 12px; border-radius: 50%; background: #FF5F57"></span>'
            '<span style="width: 12px; height: 12px; border-radius: 50%; background: #FEBC2E"></span><span style="width: 12px; height: 12px; border-radius: 50%; background: #28C840"></span></div>')

def titlebar(project="ledger-api", branch="feat/transfer-limits", phases=PHASES, cur=3, progress="4/7", env=("4/5 up", None)):
    segs = []
    for i, p in enumerate(phases):
        if cur >= 0 and i < cur:
            segs.append(f'<li><a href="Plan.dc.html" style="display: flex; align-items: center; gap: 5px; padding: 5px 10px; border-radius: 7px; font-size: 12px; color: {TX2}">{ic("check", 12, GRN, 2.5)}{p}</a></li>')
        elif i == cur:
            segs.append(f'<li><a href="Plan.dc.html" aria-current="step" style="display: flex; align-items: center; gap: 7px; padding: 5px 11px; border-radius: 7px; font-size: 12px; font-weight: 600; background: {ACC}; color: {ON_ACC}">{p}<span style="font-family: {MONO}; font-size: 11px; font-weight: 500; opacity: 0.75">{progress}</span></a></li>')
        else:
            segs.append(f'<li><a href="Plan.dc.html" style="display: flex; align-items: center; padding: 5px 10px; border-radius: 7px; font-size: 12px; color: {TX3}">{p}</a></li>')
    env_txt, env_col = env
    env_col = env_col or AMB
    return f'''<header style="display: flex; align-items: center; gap: 16px; min-height: 52px; padding: 8px 16px; box-sizing: border-box; background: {PANEL}; border-bottom: 1px solid {LINE}; flex-wrap: wrap">
{traffic()}
<button type="button" style="display: flex; align-items: center; gap: 8px; background: transparent; border: 0; color: {TX}; padding: 6px 8px; border-radius: 6px; font-size: 13px; font-weight: 600">{project}<span style="display: flex; align-items: center; gap: 5px; color: {TX3}; font-weight: 400">{ic("branch", 13)}{branch}</span>{ic("chevd", 13, TX3)}</button>
<nav aria-label="Lifecycle phases" style="flex: 1 1 520px; display: flex; justify-content: center; min-width: 0">
<ol style="display: flex; flex-wrap: wrap; gap: 2px; list-style: none; margin: 0; padding: 3px; background: {CARD}; border: 1px solid {LINE}; border-radius: 10px">
{"".join(segs)}
</ol>
</nav>
<div style="display: flex; align-items: center; gap: 8px">
<a href="Environments.dc.html" style="display: flex; align-items: center; gap: 6px; padding: 5px 9px; border-radius: 7px; border: 1px solid {LINE}; color: {TX2}; font-size: 12px">{dot(env_col, 7)}{env_txt}</a>
<a href="Palette.dc.html" style="display: flex; align-items: center; gap: 8px; padding: 5px 9px; border-radius: 7px; border: 1px solid {LINE}; color: {TX3}; font-size: 12px">{ic("search", 13)}Search or ask<span style="font-family: {MONO}; font-size: 11px">⌘K</span></a>
<a href="Build.dc.html" style="display: flex; align-items: center; gap: 6px; padding: 5px 10px; border-radius: 7px; background: {ACC_BG}; border: 1px solid {ACC_LINE}; color: {ACC}; font-size: 12px; font-weight: 500">{ic("chat", 14)}Claude</a>
</div>
</header>'''

RAIL = [("Overview.dc.html", "Home", "home"), ("Plan.dc.html", "Plan", "plan"), ("Architecture.dc.html", "Map", "diagram"),
        ("Build.dc.html", "Code", "code"), ("Test.dc.html", "Tests", "flask"), ("Environments.dc.html", "Env", "box"),
        ("Release.dc.html", "Ship", "rocket"), ("Operate.dc.html", "Run", "pulse")]

def rail(active):
    def item(href, label, icon):
        on = href == active
        style = (f"width: 56px; height: 50px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; "
                 f"border-radius: 10px; font-size: 10.5px; font-weight: 500; "
                 + (f"background: {ACC_BG}; color: {ACC}" if on else f"color: {TX3}"))
        cur = ' aria-current="page"' if on else ""
        return f'<a href="{href}"{cur} style="{style}">{ic(icon, 19)}{label}</a>'
    items = "".join(item(*r) for r in RAIL)
    return f'''<nav aria-label="Workspace" style="flex: 0 0 72px; display: flex; flex-direction: column; align-items: center; gap: 2px; padding: 10px 0; box-sizing: border-box; background: {PANEL}; border-right: 1px solid {LINE}">
{items}
<div style="flex: 1 1 auto"></div>
{item("Spec.paper.dc.html", "Docs", "paper")}
{item("ProjectFormat.dc.html", "Spec", "book")}
</nav>'''

def static_script(h=920):
    return ('<script type="text/x-dc" data-dc-script data-props=\'{"$preview":{"width":1440,"height":' + str(h) + '}}\'>\n'
            'class Component extends DCLogic {\n  renderVals() {\n    return {};\n  }\n}\n</script>')

def write(fname, html):
    with open(os.path.join(ROOT, fname), "w") as f:
        f.write(html)

def page(fname, title, active, content, extra_css="", overlay="", serif=False, tb=None, h=920):
    tb = tb if tb is not None else titlebar()
    html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
{font_link(serif)}
<style>
{base_css()}{extra_css}
</style>
</helmet>
<div style="position: relative; min-height: 100vh; display: flex; flex-direction: column; background: {BG}; color: {TX}">
{tb}
<div style="flex: 1 1 auto; display: flex; flex-wrap: wrap; min-height: 0">
{rail(active)}
{content}
</div>
{overlay}
</div>
</x-dc>
{static_script(h)}
</body>
</html>
'''
    write(fname, html)

def page_header(eyebrow_txt, title, sub, right=""):
    return (f'<div style="display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: space-between; gap: 16px">'
            f'<div style="display: flex; flex-direction: column; gap: 6px; min-width: 0">{eyebrow(eyebrow_txt)}'
            f'<h1 style="margin: 0; font-size: 26px; font-weight: 600; letter-spacing: -0.02em">{title}</h1>'
            f'<p style="margin: 0; color: {TX2}; font-size: 13.5px; max-width: 720px; text-wrap: pretty">{sub}</p></div>'
            f'<div style="display: flex; gap: 8px; flex-wrap: wrap; align-items: center">{right}</div></div>')

MAIN_COL = "flex: 999 1 560px; min-width: 0; padding: 28px 32px 40px; box-sizing: border-box; display: flex; flex-direction: column; gap: 22px"

def grid(minw, inner, gap=16):
    return f'<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min({minw}px, 100%), 1fr)); gap: {gap}px">{inner}</div>'

def row(left, right, extra=""):
    return f'<div style="display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; {extra}">{left}{right}</div>'

def crit(done, text, note=""):
    mark = (f'<span aria-hidden="true" style="width: 18px; height: 18px; border-radius: 5px; background: {GRN_BG}; display: flex; align-items: center; justify-content: center; flex: 0 0 auto">{ic("check", 12, GRN, 2.5)}</span>'
            if done else f'<span aria-hidden="true" style="width: 16px; height: 16px; border-radius: 5px; border: 1.5px solid {LINE2}; flex: 0 0 auto"></span>')
    n = f'<span style="color: {AMB}; font-size: 12px; white-space: nowrap">{note}</span>' if note else ""
    col = TX2 if done else TX
    return f'<li style="display: flex; align-items: center; gap: 10px; color: {col}">{mark}<span style="flex: 1 1 auto">{text}</span>{n}</li>'

def phase_dots(cur, total=7):
    out = []
    for i in range(total):
        c = DONE if i < cur else (ACC if i == cur else TRACK)
        out.append(f'<span style="width: 6px; height: 6px; border-radius: 50%; background: {c}"></span>')
    return f'<span aria-hidden="true" style="display: flex; gap: 3px">{"".join(out)}</span>'

def ul(inner, gap=0):
    return f'<ul style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: {gap}px">{inner}</ul>'

def li_row(inner, top=True, pad="10px 0"):
    return f'<li style="display: flex; align-items: center; gap: 12px; padding: {pad}; {"border-top: 1px solid " + LINE if top else ""}">{inner}</li>'

def mono(t, col=None, size=12):
    return f'<span style="font-family: {MONO}; font-size: {size}px; color: {col or TX2}">{t}</span>'

# ---------- diagram primitives ----------
def arrow(x, y, n, direction, color=None, dashed=False, width=2):
    color = color or ARROW
    head = ('<defs><marker id="dc-arrow-head-filled" orient="auto" markerWidth="5" markerHeight="5" refX="3.2" refY="2" overflow="visible">'
            f'<path d="M0 0 L4 2 L0 4 Z" fill="{color}" stroke="none" style="fill: context-stroke"/></marker></defs>')
    dash = "; stroke-dasharray: 6 6" if dashed else ""
    st = f"overflow: visible; fill: none; stroke: {color}; stroke-width: {width}; stroke-linecap: round; stroke-linejoin: round{dash}"
    if direction in ("right", "left"):
        d = f"M 0 4 L {n} 4" if direction == "right" else f"M {n} 4 L 0 4"
        return (f'<svg width="{n}" height="8" viewBox="0 0 {n} 8" preserveAspectRatio="none" style="position: absolute; left: {x}px; top: {y-4}px; width: {n}px; height: 8px; {st}">'
                f'{head}<path d="{d}" marker-end="url(#dc-arrow-head-filled)"></path></svg>')
    d = f"M 4 0 L 4 {n}" if direction == "down" else f"M 4 {n} L 4 0"
    return (f'<svg width="8" height="{n}" viewBox="0 0 8 {n}" preserveAspectRatio="none" style="position: absolute; left: {x-4}px; top: {y}px; width: 8px; height: {n}px; {st}">'
            f'{head}<path d="{d}" marker-end="url(#dc-arrow-head-filled)"></path></svg>')

def vline(x, y, n, color=None, dashed=True):
    color = color or LINE2
    dash = "; stroke-dasharray: 4 6" if dashed else ""
    return (f'<svg width="8" height="{n}" viewBox="0 0 8 {n}" preserveAspectRatio="none" style="position: absolute; left: {x-4}px; top: {y}px; width: 8px; height: {n}px; '
            f'overflow: visible; fill: none; stroke: {color}; stroke-width: 1.5; stroke-linecap: round{dash}"><path d="M 4 0 L 4 {n}"></path></svg>')

def hline(x, y, n, color=None, dashed=True):
    color = color or LINE2
    dash = "; stroke-dasharray: 6 6" if dashed else ""
    return (f'<svg width="{n}" height="8" viewBox="0 0 {n} 8" preserveAspectRatio="none" style="position: absolute; left: {x}px; top: {y-4}px; width: {n}px; height: 8px; '
            f'overflow: visible; fill: none; stroke: {color}; stroke-width: 2; stroke-linecap: round{dash}"><path d="M 0 4 L {n} 4"></path></svg>')

def alabel(text, left, top, w, col=None, weight=400):
    return f'<div style="position: absolute; left: {left}px; top: {top}px; width: {w}px; text-align: center; font-size: 11.5px; line-height: 16px; font-family: {MONO}; color: {col or TX3}; font-weight: {weight}">{text}</div>'

def node(title, sub, left, top, w, kind="normal", badge="", h=72):
    if kind == "sel":
        b, bg = f"1.5px solid {ACC}", ACC_BG
    elif kind == "ext":
        b, bg = f"1px dashed {LINE2}", PANEL
    elif kind == "warn":
        b, bg = f"1px solid {WARN_BORDER}", RAISED
    else:
        b, bg = f"1px solid {LINE2}", RAISED
    return (f'<div style="position: absolute; left: {left}px; top: {top}px; width: {w}px; height: {h}px; box-sizing: border-box; padding: 8px 12px; '
            f'display: flex; align-items: center; justify-content: center; text-align: center; background: {bg}; border: {b}; border-radius: 10px; '
            f'box-shadow: {SHADOW}"><span><b style="font-weight: 600; font-size: 13.5px; color: {TX}">{title}</b>{badge}<br>'
            f'<span style="font-family: {MONO}; font-size: 11px; color: {TX3}">{sub}</span></span></div>')

def band(left, top, w, h, label, lcol=None):
    return (f'<div style="position: absolute; left: {left}px; top: {top}px; width: {w}px; height: {h}px; box-sizing: border-box; border: 1px dashed {LINE2}; border-radius: 14px; background: {HL}"></div>'
            f'<div style="position: absolute; left: {left + 14}px; top: {top + 10}px; font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; color: {lcol or TX3}; font-weight: 500">{label}</div>')

def canvas_box(inner, pad="8px 0"):
    return (f'<div style="border: 1px solid {LINE}; border-radius: 12px; background-color: {PANEL}; background-image: radial-gradient({DOT} 1px, transparent 1px); '
            f'background-size: 20px 20px; overflow: auto; display: flex; justify-content: center; padding: {pad}">{inner}</div>')

def kv(k, v):
    return f'<div style="display: flex; justify-content: space-between; gap: 12px; padding: 8px 0; border-top: 1px solid {LINE}"><span style="color: {TX3}">{k}</span><span style="text-align: right">{v}</span></div>'

def inspector(inner, label="Inspector"):
    return f'''<aside aria-label="{label}" style="flex: 1 1 300px; max-width: 100%; box-sizing: border-box; padding: 24px 22px; background: {PANEL}; border-left: 1px solid {LINE}; display: flex; flex-direction: column; gap: 18px">{inner}</aside>'''

def map_tabs(on):
    tabs = [("Architecture.dc.html", "Architecture", "diagram"), ("Flow.dc.html", "Flows", "flow"), ("DataModel.dc.html", "Data model", "db"), ("Cloud.dc.html", "Cloud", "cloud")]
    out = "".join(f'<a href="{h}" {"aria-current=" + chr(34) + "page" + chr(34) if l == on else ""} style="display: flex; align-items: center; gap: 7px; padding: 6px 12px; border-radius: 7px; font-size: 12.5px; '
                  + (f'background: {CARD}; color: {TX}; font-weight: 500; box-shadow: 0 0 0 1px {LINE2}' if l == on else f'color: {TX3}') + f'">{ic(i, 14)}{l}</a>' for h, l, i in tabs)
    return f'<nav aria-label="Map views" style="display: flex; gap: 2px; padding: 3px; background: {PANEL}; border: 1px solid {LINE}; border-radius: 9px; align-self: flex-start; flex-wrap: wrap">{out}</nav>'

# ======================================================================
# Overview
# ======================================================================
def overview(fname="Overview.dc.html"):
    crits = "".join([
        crit(True, f'API contract frozen <span style="font-family: {MONO}; font-size: 12px; color: {TX3}">openapi.yaml v1.3</span>'),
        crit(True, "Migrations reviewed"),
        crit(True, "Transfer limits implemented"),
        crit(True, "Feature flags wired"),
        crit(False, "Unit coverage ≥ 80% on ledger-core", "now 71%"),
        crit(False, "Idempotency keys on POST /transfers", "LED-48"),
        crit(False, "ADR-012 decided: outbox vs. CDC", "proposed"),
    ])
    timeline_items = []
    dates = ["Jun 2", "Jun 20", "Jul 14", "since Aug 4", "", "", ""]
    for i, p in enumerate(PHASES):
        if i < 3:
            top = f'<div style="height: 4px; border-radius: 2px; background: {DONE}"></div>'
            label = f'<div style="display: flex; align-items: center; gap: 6px; color: {TX2}; font-size: 12.5px">{ic("check", 12, GRN, 2.5)}{p}</div>'
            sub = f'<div style="color: {TX3}; font-size: 11.5px">Done {dates[i]}</div>'
        elif i == 3:
            top = f'<div style="height: 4px; border-radius: 2px; background: {TRACK}; display: flex"><div style="width: 57%; background: {ACC}; border-radius: 2px"></div></div>'
            label = f'<div style="color: {TX}; font-size: 12.5px; font-weight: 600">{p}</div>'
            sub = f'<div style="color: {ACC}; font-size: 11.5px">In progress {dates[i]}</div>'
        else:
            top = f'<div style="height: 4px; border-radius: 2px; background: {TRACK}"></div>'
            label = f'<div style="color: {TX3}; font-size: 12.5px">{p}</div>'
            sub = f'<div style="color: {TX3}; font-size: 11.5px">Not started</div>'
        timeline_items.append(f'<a href="Plan.dc.html" style="display: flex; flex-direction: column; gap: 8px; min-width: 0; color: inherit">{top}{label}{sub}</a>')
    timeline = f'<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min(110px, 100%), 1fr)); gap: 10px">{"".join(timeline_items)}</div>'

    phase_card = card(
        row(f'<div style="display: flex; flex-direction: column; gap: 4px">{eyebrow("Current phase")}<div style="font-size: 20px; font-weight: 600; letter-spacing: -0.01em">Build</div><div style="color: {TX2}">Turn the agreed design into working, reviewed code.</div></div>',
            f'<div style="display: flex; flex-direction: column; align-items: flex-end; gap: 4px"><div style="font-family: {MONO}; font-size: 22px; font-weight: 500">4<span style="color: {TX3}">/7</span></div><div style="color: {TX3}; font-size: 12px">checklist done</div></div>')
        + ul(crits, 10)
        + row(f'<span style="color: {TX3}; font-size: 12px">Up next: <b style="color: {TX2}; font-weight: 500">Test</b>. Move on whenever you’re ready.</span>', btn("Open phase", href="Plan.dc.html")))

    def task(id_, title, state, scol, who):
        return li_row(f'<span style="font-family: {MONO}; font-size: 11.5px; color: {TX3}; width: 52px; flex: 0 0 auto">{id_}</span>'
                      f'<span style="flex: 1 1 auto; min-width: 0">{title}</span>'
                      f'<span style="font-size: 12px; color: {TX3}; white-space: nowrap">{who}</span>'
                      f'<span style="display: flex; align-items: center; gap: 6px; font-size: 12px; color: {scol}; white-space: nowrap; width: 96px; justify-content: flex-end">{dot(scol, 6)}{state}</span>')
    tasks = card(card_head("Build tasks", f'<a href="Plan.dc.html" style="font-size: 12px">Board</a>')
                 + ul(task("LED-42", "Enforce daily transfer limits", "In progress", ACC, "with Claude")
                      + task("LED-51", "Balance query p95 above 120 ms", "In progress", ACC, "")
                      + task("LED-39", "Seed data for staging", "Review", AMB, "")
                      + task("LED-48", "Idempotency keys on POST /transfers", "Ready", TX3, "")))

    def mini(label, x, y, w, sel=False):
        b = f"1.5px solid {ACC}" if sel else f"1px solid {LINE2}"
        bg = ACC_BG if sel else RAISED
        return f'<div style="position: absolute; left: {x}px; top: {y}px; width: {w}px; height: 32px; box-sizing: border-box; border: {b}; background: {bg}; border-radius: 7px; display: flex; align-items: center; justify-content: center; font-size: 11px; color: {TX2}">{label}</div>'
    def hl(x, y, w):
        return f'<div style="position: absolute; left: {x}px; top: {y}px; width: {w}px; height: 1px; background: {LINE2}"></div>'
    def vl(x, y, h):
        return f'<div style="position: absolute; left: {x}px; top: {y}px; width: 1px; height: {h}px; background: {LINE2}"></div>'
    minimap = (f'<div style="position: relative; height: 150px; border-radius: 8px; background-color: {PANEL}; background-image: radial-gradient({DOT} 1px, transparent 1px); background-size: 16px 16px; overflow: hidden">'
               + hl(84, 35, 20) + hl(174, 35, 20) + vl(139, 51, 32) + hl(174, 99, 110) + vl(319, 115, 16)
               + mini("Gateway", 14, 19, 70) + mini("Ledger", 104, 19, 70, True) + mini("Redis", 194, 19, 70)
               + mini("Postgres", 104, 83, 70) + mini("NATS", 284, 83, 70) + mini("Worker", 284, 131, 70) + '</div>')
    arch = card(card_head("Architecture", '<a href="Architecture.dc.html" style="font-size: 12px">Open map</a>') + minimap
                + f'<div style="display: flex; align-items: center; gap: 8px; color: {TX3}; font-size: 12px">{ic("refresh", 13)}Regenerated 3 min ago<span style="margin-left: auto; display: flex; align-items: center; gap: 6px; color: {AMB}">{ic("alert", 13, AMB)}2 mismatches</span></div>')

    def svc(name, status, col, detail):
        return li_row(f'{dot(col, 7)}<span style="font-family: {MONO}; font-size: 12px; flex: 1 1 auto">{name}</span>'
                      f'<span style="font-size: 12px; color: {TX3}">{detail}</span>'
                      f'<span style="font-size: 12px; color: {col}; width: 76px; text-align: right">{status}</span>', pad="8px 0")
    env = card(card_head("Local environment", '<a href="Environments.dc.html" style="font-size: 12px">Containers</a>')
               + ul(svc("api-gateway", "running", GRN, ":8080") + svc("ledger-service", "running", GRN, ":3001")
                    + svc("notification-worker", "restarting", AMB, "exit 1 ×3") + svc("postgres", "healthy", GRN, ":5432")
                    + svc("redis", "running", GRN, ":6379")))

    def adr(id_, title, state, col):
        return li_row(f'<span style="font-family: {MONO}; font-size: 11.5px; color: {TX3}; width: 64px">{id_}</span><span style="flex: 1 1 auto">{title}</span>'
                      f'<span style="font-size: 12px; color: {col}">{state}</span>', pad="9px 0")
    decisions = card(card_head("Decisions", '<a href="Spec.paper.dc.html" style="font-size: 12px">All 12</a>')
                     + ul(adr("ADR-012", "Outbox vs. change-data-capture for events", "Proposed", AMB)
                          + adr("ADR-011", "Money stored as integer minor units", "Accepted", TX3)
                          + adr("ADR-010", "Advisory lock per account for transfers", "Accepted", TX3)))

    def ctx(label, val):
        return f'<li style="display: flex; justify-content: space-between; gap: 12px; padding: 7px 0; border-top: 1px solid {LINE}"><span style="color: {TX2}">{label}</span><span style="font-family: {MONO}; font-size: 12px; color: {TX}">{val}</span></li>'
    agent = card(card_head("What Claude knows", f'<a href="ProjectFormat.dc.html" style="font-size: 12px">Edit spec</a>')
                 + f'<p style="margin: 0; color: {TX2}">Every task starts from the project spec, so nothing has to be re-explained.</p>'
                 + ul(ctx("Charter and goals", "project.yaml") + ctx("Phase definitions", "7") + ctx("Decisions", "12 ADRs")
                      + ctx("Architecture model", "8 nodes") + ctx("Build rules", "edit src/, test/")))

    def doc(icon_col, text, action, href="Spec.paper.dc.html"):
        return li_row(f'{dot(icon_col, 6)}<span style="flex: 1 1 auto">{text}</span><a href="{href}" style="font-size: 12px; white-space: nowrap">{action}</a>', pad="9px 0")
    docs = card(card_head("Documentation", '<a href="Spec.paper.dc.html" style="font-size: 12px">Read</a>')
                + ul(doc(AMB, "3 endpoints missing from openapi.yaml", "Draft")
                     + doc(AMB, "No runbook for notification-worker", "Draft")
                     + doc(GRN, "transfer-limits.md matches the code", "Open")))

    content = f'''<main style="{MAIN_COL}">
{page_header("Project", "ledger-api", "Double-entry ledger service: accounts, transfers and balance queries for internal payments.",
             chip(ic("code", 13) + "TypeScript") + chip(ic("box", 13) + "5 services") + chip(ic("branch", 13) + "feat/transfer-limits"))}
{card(timeline, "padding: 16px 20px")}
<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min(380px, 100%), 1fr)); gap: 16px">
{phase_card}
{tasks}
</div>
{grid(300, arch + env + agent + decisions + docs)}
</main>'''
    page(fname, "Project home" + (" light" if THEME == "light" else ""), "Overview.dc.html", content)

# ======================================================================
# Architecture
# ======================================================================
def architecture():
    warn_badge = f' <span style="color: {AMB}; font-size: 11px; font-weight: 500">· mismatch</span>'
    diagram = ('<div style="position: relative; width: 1000px; height: 508px; flex: 0 0 auto">'
               + arrow(208, 104, 78, "right") + arrow(464, 104, 78, "right") + arrow(736, 104, 78, "right")
               + arrow(640, 140, 94, "down") + arrow(736, 272, 78, "right") + arrow(892, 308, 94, "down")
               + arrow(738, 440, 78, "left")
               + node("Web dashboard", "React SPA · external", 32, 68, 176, "ext")
               + node("API gateway", "src/gateway · :8080", 288, 68, 176)
               + node("Ledger service", "src/ledger · :3001", 544, 68, 192, "sel")
               + node("Redis", "cache · :6379", 816, 68, 152, "warn", warn_badge)
               + node("Postgres 16", "ledger schema", 544, 236, 192)
               + node("NATS", "events · :4222", 816, 236, 152, "warn", warn_badge)
               + node("Notification worker", "src/worker", 816, 404, 152)
               + node("Email provider", "SMTP · external", 544, 404, 192, "ext")
               + alabel("HTTPS", 220, 76, 56) + alabel("REST", 482, 76, 44) + alabel("cache", 752, 76, 48)
               + alabel("SQL", 652, 179, 32) + alabel("outbox", 748, 244, 56) + alabel("events", 904, 347, 52)
               + alabel("SMTP", 754, 412, 44)
               + '</div>')

    toolbar = (f'<div style="display: flex; flex-wrap: wrap; align-items: center; gap: 12px">'
               + seg_group("Zoom level", ["Context", "Containers", "Components", "Code"], "Containers")
               + f'<div style="margin-left: auto; display: flex; gap: 8px">{btn("Export", icon="export")}{btn("Regenerate", icon="refresh")}</div></div>')

    def drift(title, detail, src, actions):
        return (f'<li style="display: flex; gap: 12px; padding: 12px 0; border-top: 1px solid {LINE}; align-items: flex-start; flex-wrap: wrap">{ic("alert", 16, AMB)}'
                f'<div style="flex: 1 1 300px; display: flex; flex-direction: column; gap: 3px; min-width: 0"><span style="font-weight: 500">{title}</span>'
                f'<span style="color: {TX2}">{detail}</span><span style="font-family: {MONO}; font-size: 11.5px; color: {TX3}">{src}</span></div>'
                f'<div style="display: flex; gap: 6px; flex-wrap: wrap">{actions}</div></li>')
    drift_card = card(card_head("Where the code and the documented architecture disagree", f'<span style="color: {TX3}; font-size: 12px">2 found</span>')
                      + ul(drift("Redis is used but not documented", "ledger-service caches balances in Redis; architecture.md does not mention it.", "src/ledger/balance.ts:12", btn("Add to model") + btn("Ignore"))
                           + drift("NATS is imported but not in docker-compose.yml", "notification-worker subscribes to NATS, but no NATS container runs locally. That is why it keeps restarting.", "src/worker/subscribe.ts:8", btn("Add service", True) + btn("Open logs", href="Environments.dc.html"))))

    main = f'''<main style="flex: 999 1 640px; min-width: 0; padding: 24px 28px 36px; box-sizing: border-box; display: flex; flex-direction: column; gap: 18px">
{map_tabs("Architecture")}
{page_header("Map · ledger-api", "Containers", "Generated from docker-compose.yml, source imports, openapi.yaml and your notes in architecture.md. Zoom out for the system context or in for components.")}
{toolbar}
{canvas_box(diagram)}
{drift_card}
</main>'''

    insp = inspector(f'''<div style="display: flex; flex-direction: column; gap: 6px">{eyebrow("Selected")}<div style="font-size: 18px; font-weight: 600">Ledger service</div>
<p style="margin: 0; color: {TX2}">Owns accounts and transfers. Every transfer takes a per-account advisory lock, then writes two balanced entries.</p></div>
<div>
{kv("Path", mono("src/ledger/**", TX))}
{kv("Endpoints", mono("POST /transfers<br>GET /accounts/:id/balance", TX))}
{kv("Depends on", "Postgres, Redis, NATS")}
{kv("Tests", f'142 · <span style="color: {AMB}">71% coverage</span>')}
{kv("Open tasks", '<a href="Plan.dc.html">LED-42, LED-48, LED-51</a>')}
</div>
<div style="display: flex; flex-direction: column; gap: 8px">{eyebrow("Linked docs")}
<div style="display: flex; flex-wrap: wrap; gap: 6px">{mono_chip("specs/transfer-limits.md")}{mono_chip("ADR-010")}{mono_chip("ADR-011")}</div></div>
<div style="display: flex; flex-direction: column; gap: 8px; margin-top: auto">
{btn("Trace a flow through it", icon="flow", href="Flow.dc.html")}
{btn("Open code", icon="code", href="Build.dc.html")}
{btn("Ask Claude to walk through it", True, "chat", "Build.dc.html")}
</div>''')
    page("Architecture.dc.html", "Architecture map", "Architecture.dc.html", main + insp)

# ======================================================================
# Flow (sequence)
# ======================================================================
def flow():
    lanes = [("Client", "web"), ("API gateway", "src/gateway"), ("Ledger service", "src/ledger"), ("Postgres", "ledger db"), ("NATS", "events"), ("Worker", "src/worker")]
    cx = [84, 252, 420, 588, 756, 924]
    W_ = 136
    out = []
    for x in cx:
        out.append(vline(x, 80, 556))
    # messages: (from, to, y, label, selected)
    msgs = [(0, 1, 128, "POST /transfers"), (1, 2, 176, "createTransfer()"), (2, 3, 224, "BEGIN; lock account"),
            (2, 3, 272, "sum outbound today"), (2, 3, 320, "insert entries+outbox"), (2, 3, 368, "COMMIT"),
            (2, 1, 416, "201 Created"), (1, 0, 464, "201 Created"), (3, 4, 528, "transfer.created"), (4, 5, 584, "deliver receipt")]
    labels = []
    for i, (a, b, y, lab) in enumerate(msgs, 1):
        sel = i == 4
        col = ACC if sel else ARROW
        if b > a:
            x0 = cx[a]; n = cx[b] - cx[a] - 2
            out.append(arrow(x0, y, n, "right", col, width=2.5 if sel else 2))
        else:
            x0 = cx[b] + 2; n = cx[a] - cx[b] - 2
            out.append(arrow(x0, y, n, "left", col, dashed=True))
        mid = (cx[a] + cx[b]) // 2
        w = 160
        labels.append(alabel(f"{i} · {lab}", mid - w // 2, y - 24, w, ACC if sel else TX2, 600 if sel else 400))
    heads = "".join(node(n, s, x - W_ // 2, 24, W_, "sel" if n == "Ledger service" else ("ext" if n == "Client" else "normal"), h=56) for (n, s), x in zip(lanes, cx))
    # async divider
    divider = (f'<div style="position: absolute; left: 24px; top: 488px; width: 960px; height: 1px; background: {LINE2}"></div>'
               f'<div style="position: absolute; left: 32px; top: 492px; font-size: 11px; color: {TX3}; font-family: {MONO}">after commit · async</div>')
    diagram = '<div style="position: relative; width: 1008px; height: 640px; flex: 0 0 auto">' + "".join(out) + divider + heads + "".join(labels) + '</div>'

    flows = [("Create transfer", "10 steps", True), ("Get balance", "5 steps", False), ("Nightly reconciliation", "14 steps", False), ("Send receipt", "6 steps", False)]
    flist = "".join(f'<li><a href="Flow.dc.html" style="display: flex; flex-direction: column; gap: 2px; padding: 9px 12px; border-radius: 8px; '
                    + (f'background: {ACC_BG}; color: {TX}' if on else f'color: {TX2}') + f'"><span style="font-weight: {600 if on else 400}">{n}</span><span style="font-size: 11.5px; color: {TX3}">{s}</span></a></li>' for n, s, on in flows)
    side = f'''<aside aria-label="Flows" style="flex: 0 0 220px; box-sizing: border-box; padding: 24px 10px; background: {PANEL}; border-right: 1px solid {LINE}; display: flex; flex-direction: column; gap: 12px">
<div style="padding: 0 12px">{eyebrow("Flows")}</div>
{ul(flist, 2)}
<div style="margin: 6px 12px 0; padding-top: 12px; border-top: 1px solid {LINE}; color: {TX3}; font-size: 12px">Found by following calls from each API route and queue consumer, then confirmed against a traced test run.</div>
</aside>'''

    main = f'''<main style="flex: 999 1 640px; min-width: 0; padding: 24px 28px 36px; box-sizing: border-box; display: flex; flex-direction: column; gap: 18px">
{map_tabs("Flows")}
{page_header("Flow · ledger-api", "Create transfer", "One request, step by step across services. Click a step to see the code that runs it.",
             seg_group("Detail", ["Services", "Functions"], "Services") + btn("Replay trace", icon="play"))}
{canvas_box(diagram)}
</main>'''

    code = [
        f'<span style="color: {K}">await</span> tx.<span style="color: {F}">lockAccount</span>(from);',
        f'<span style="color: {K}">const</span> sent = <span style="color: {K}">await</span> tx.transfers',
        f'  .<span style="color: {F}">sumOutbound</span>(from, <span style="color: {F}">startOfDayUtc</span>());',
        f'<span style="color: {K}">if</span> (sent.<span style="color: {F}">plus</span>(amount).<span style="color: {F}">greaterThan</span>(limit))',
        f'  <span style="color: {K}">throw new</span> <span style="color: {T}">LimitExceeded</span>(…);',
    ]
    snippet = (f'<div style="font-family: {MONO}; font-size: 11.5px; line-height: 19px; background: {CODE_BG}; border: 1px solid {LINE}; border-radius: 8px; padding: 10px 12px; overflow-x: auto">'
               + "".join(f'<div style="white-space: pre">{l}</div>' for l in code) + '</div>')
    insp = inspector(f'''<div style="display: flex; flex-direction: column; gap: 6px">{eyebrow("Step 4 of 10")}<div style="font-size: 18px; font-weight: 600">Sum outbound today</div>
<p style="margin: 0; color: {TX2}">Adds up what the account has sent since 00:00 UTC, inside the lock taken in step 3, so two transfers can’t both slip under the limit.</p></div>
<div>
{kv("Function", mono("checkDailyLimit", TX))}
{kv("Location", '<a href="Build.dc.html" style="font-family: ' + MONO + '; font-size: 12px">src/ledger/limits.ts:14</a>')}
{kv("Query", mono("idx_transfers_from_created", TX))}
{kv("Traced time", mono("3.1 ms", TX))}
</div>
{snippet}
<div style="display: flex; gap: 10px; align-items: flex-start; padding: 10px 12px; border-radius: 10px; background: {GRN_BG}; color: {TX}; font-size: 12.5px">{ic("check", 15, GRN, 2.25)}<span>Matches ADR-010: the limit is checked after the lock is taken.</span></div>
<div style="display: flex; flex-direction: column; gap: 8px; margin-top: auto">
{btn("Open in code", icon="code", href="Build.dc.html")}
{btn("Add this diagram to the spec", True, "paper", "Spec.paper.dc.html")}
</div>''')
    page("Flow.dc.html", "Process flow", "Architecture.dc.html", side + main + insp)

# ======================================================================
# Data model
# ======================================================================
def table_card(name, cols, left, top, w, sel=False, note=""):
    h = 40 + len(cols) * 20
    b = f"1.5px solid {ACC}" if sel else f"1px solid {LINE2}"
    rows = "".join(
        f'<br><span style="font-family: {MONO}; font-size: 11.5px; color: {c[2] if len(c) > 2 else TX2}">{c[0]} <span style="color: {TX3}">{c[1]}</span></span>' for c in cols)
    return (f'<div style="position: absolute; left: {left}px; top: {top}px; width: {w}px; height: {h}px; box-sizing: border-box; padding: 10px 14px; '
            f'display: flex; align-items: flex-start; text-align: left; line-height: 20px; background: {ACC_BG if sel else RAISED}; border: {b}; border-radius: 10px; box-shadow: {SHADOW}">'
            f'<span><b style="font-weight: 600; font-size: 13px; color: {TX}">{name}</b>{note}{rows}</span></div>')

def datamodel():
    new = f' <span style="color: {GRN}; font-size: 10.5px">new</span>'
    diagram = ('<div style="position: relative; width: 1012px; height: 470px; flex: 0 0 auto">'
               + arrow(234, 96, 166, "left") + arrow(132, 182, 118, "up") + arrow(510, 222, 78, "up")
               + hline(620, 96, 160) + hline(620, 360, 160)
               + table_card("accounts", [("id", "uuid pk"), ("owner_id", "uuid"), ("currency", "char(3)"), ("status", "text"), ("created_at", "timestamptz")], 32, 40, 200)
               + table_card("account_limits", [("account_id", "uuid pk fk"), ("daily_minor", "bigint"), ("updated_at", "timestamptz")], 32, 300, 200, note=new)
               + table_card("transfers", [("id", "uuid pk"), ("from_account_id", "fk"), ("to_account_id", "fk"), ("amount_minor", "bigint"), ("currency", "char(3)"), ("idempotency_key", "text", GRN), ("created_at", "timestamptz")], 400, 40, 220, sel=True)
               + table_card("entries", [("id", "uuid pk"), ("transfer_id", "fk"), ("account_id", "fk", AMB), ("amount_minor", "bigint"), ("direction", "debit|credit")], 400, 300, 220)
               + table_card("outbox", [("id", "bigserial pk"), ("topic", "text"), ("payload", "jsonb"), ("published_at", "timestamptz")], 780, 40, 200)
               + table_card("audit_log", [("id", "bigserial pk"), ("account_id", "uuid"), ("event", "text"), ("created_at", "timestamptz")], 780, 300, 200)
               + alabel("from / to", 276, 72, 80) + alabel("1 : 1", 144, 239, 40) + alabel("transfer_id", 522, 253, 88)
               + alabel("same tx", 668, 72, 64) + alabel("on reject", 664, 336, 72)
               + '</div>')

    main = f'''<main style="flex: 999 1 640px; min-width: 0; padding: 24px 28px 36px; box-sizing: border-box; display: flex; flex-direction: column; gap: 18px">
{map_tabs("Data model")}
{page_header("Map · ledger-api", "Data model", "Read from migrations/ (7 files). Arrows point from a foreign key to the table it references; dashed lines are writes in the same transaction.",
             seg_group("Compare", ["main", "this branch"], "this branch") + btn("Export", icon="export"))}
{canvas_box(diagram, "16px 0")}
{card(card_head("Findings") + ul(
    li_row(f'{ic("alert", 16, AMB)}<span style="flex: 1 1 auto"><b style="font-weight: 500">entries.account_id has no index.</b> <span style="color: {TX2}">Balance queries scan the whole table, which is likely behind LED-51 (p95 above 120 ms).</span></span>{btn("Draft migration")}')
    + li_row(f'{ic("check", 16, GRN, 2.25)}<span style="flex: 1 1 auto"><b style="font-weight: 500">transfers(from_account_id, created_at) is indexed.</b> <span style="color: {TX2}">The daily limit query uses it.</span></span>')))}
</main>'''
    insp = inspector(f'''<div style="display: flex; flex-direction: column; gap: 6px">{eyebrow("Selected table")}<div style="font-size: 18px; font-weight: 600; font-family: {MONO}">transfers</div>
<p style="margin: 0; color: {TX2}">One row per money movement. The two balanced rows in entries are written in the same transaction.</p></div>
<div>
{kv("Defined in", mono("0004_transfers.sql", TX))}
{kv("Changed in branch", mono("0007_idempotency.sql", GRN))}
{kv("Rows (local)", mono("18,204", TX))}
{kv("Indexes", mono("pk, (from_account_id, created_at),<br>unique (idempotency_key)", TX))}
{kv("Read by", mono("limits.ts, balance.ts", TX))}
</div>
<div style="display: flex; flex-direction: column; gap: 8px; margin-top: auto">
{btn("Open migration", icon="file", href="Build.dc.html")}
{btn("Ask Claude about this table", True, "chat", "Build.dc.html")}
</div>''')
    page("DataModel.dc.html", "Data model", "Architecture.dc.html", main + insp)

# ======================================================================
# Cloud (infra project)
# ======================================================================
def cloud():
    phases = ["Define", "Design", "Build", "Validate", "Change", "Operate"]
    tb = titlebar("recon-infra", "main", phases, 3, "2/5", ("no containers", GRN))
    warn = f' <span style="color: {AMB}; font-size: 11px; font-weight: 500">· unused</span>'
    diagram = ('<div style="position: relative; width: 888px; height: 488px; flex: 0 0 auto">'
               + band(16, 16, 856, 456, "AWS account · prod · eu-west-1")
               + band(48, 64, 488, 288, "VPC · 10.20.0.0/16")
               + arrow(248, 144, 86, "right") + arrow(420, 176, 78, "down") + arrow(736, 176, 78, "down")
               + arrow(506, 288, 126, "left") + arrow(736, 320, 62, "down", dashed=True)
               + node("Load balancer", "ALB · :443", 80, 112, 168, h=64)
               + node("ECS service", "ledger-service", 336, 112, 168, h=64)
               + node("ElastiCache", "redis · t4g.small", 80, 256, 168, "warn", warn, h=64)
               + node("RDS Postgres", "ledger-db", 336, 256, 168, h=64)
               + node("Step Functions", "nightly-recon", 632, 112, 208, h=64)
               + node("Lambda", "recon-worker", 632, 256, 208, h=64)
               + node("IAM role", "recon-worker-exec", 632, 384, 208, "sel", h=64)
               + alabel("443", 276, 120, 32) + alabel("5432", 432, 207, 40) + alabel("invoke", 748, 207, 52)
               + alabel("read-only", 533, 264, 72) + alabel("assumes", 748, 343, 60)
               + '</div>')

    main = f'''<main style="flex: 999 1 640px; min-width: 0; padding: 24px 28px 36px; box-sizing: border-box; display: flex; flex-direction: column; gap: 18px">
{map_tabs("Cloud")}
{page_header("Map · recon-infra · infra template", "Deployed resources", "Built from the CloudFormation templates in stacks/ and checked against the last change set. The lifecycle above comes from the infra template: Validate and Change replace Test and Release.",
             seg_group("Source", ["Templates", "Live account"], "Templates") + btn("Export", icon="export"))}
{canvas_box(diagram, "16px 0")}
{grid(260, card(card_head("Validate", f'<span style="color: {AMB}; font-size: 12px">1 warning</span>') + ul(
        li_row(f'{ic("check", 14, GRN, 2.25)}<span style="flex: 1 1 auto">cfn-lint</span>{mono("0 errors")}', False, "6px 0")
        + li_row(f'{ic("alert", 14, AMB)}<span style="flex: 1 1 auto">cfn-guard</span>{mono("1 warning")}', False, "6px 0")
        + li_row(f'{ic("check", 14, GRN, 2.25)}<span style="flex: 1 1 auto">Naming rules</span>{mono("pass")}', False, "6px 0")))
    + card(card_head("Change set preview", mono("recon-stack")) + ul(
        li_row(f'{mono("+ Add", GRN)}<span style="flex: 1 1 auto">LogGroup /recon/worker</span>', False, "6px 0")
        + li_row(f'{mono("~ Modify", AMB)}<span style="flex: 1 1 auto">recon-worker-exec policy</span>', False, "6px 0")
        + li_row(f'{mono("~ Modify", AMB)}<span style="flex: 1 1 auto">nightly-recon schedule</span>', False, "6px 0"))))}
</main>'''

    def finding(col, icon, title, detail):
        return (f'<li style="display: flex; gap: 10px; padding: 10px 0; border-top: 1px solid {LINE}; align-items: flex-start">{ic(icon, 15, col, 2)}'
                f'<span style="display: flex; flex-direction: column; gap: 2px"><span style="font-weight: 500">{title}</span><span style="color: {TX2}; font-size: 12.5px">{detail}</span></span></li>')
    insp = inspector(f'''<div style="display: flex; flex-direction: column; gap: 6px">{eyebrow("Selected")}<div style="font-size: 18px; font-weight: 600">recon-worker-exec</div>
<p style="margin: 0; color: {TX2}">Execution role for the reconciliation Lambda.</p></div>
<div>
{kv("Defined in", mono("stacks/iam/recon-role.yaml", TX))}
{kv("Trusted by", mono("lambda.amazonaws.com", TX))}
{kv("Boundary", f'<span style="color: {GRN}">attached</span>')}
{kv("Statements", mono("4", TX))}
</div>
<div style="display: flex; flex-direction: column; gap: 4px">{eyebrow("Policy review")}
{ul(finding(GRN, "check", "S3 writes are scoped", "s3:PutObject only on recon-reports/*")
    + finding(AMB, "alert", "Logs permission is too broad", "logs:* on * can be narrowed to this function’s log group.")
    + finding(GRN, "check", "Read-only database access", "rds-db:connect for the recon_ro user only"))}
</div>
<div style="display: flex; flex-direction: column; gap: 8px; margin-top: auto">
{btn("Open template", icon="file", href="Build.dc.html")}
{btn("Ask Claude to narrow the logs permission", True, "chat", "Build.dc.html")}
</div>''')
    page("Cloud.dc.html", "Cloud resources", "Architecture.dc.html", main + insp, tb=tb)

# ======================================================================
# Build (editor) + Palette overlay
# ======================================================================
def kw(t): return f'<span style="color: {K}">{t}</span>'
def st_(t): return f'<span style="color: {S}">{t}</span>'
def fn(t): return f'<span style="color: {F}">{t}</span>'
def ty(t): return f'<span style="color: {T}">{t}</span>'
def cm(t): return f'<span style="color: {C}">{t}</span>'
def nu(t): return f'<span style="color: {N}">{t}</span>'

def build_parts():
    squig = f'<span style="text-decoration: underline wavy {RED}; text-underline-offset: 4px">startOfDayUtc</span>'
    lines = [
        f'{kw("import")} {{ {ty("Money")}, minor }} {kw("from")} {st_("&quot;./money&quot;")};',
        f'{kw("import")} {{ db }} {kw("from")} {st_("&quot;../db&quot;")};',
        f'{kw("import")} {{ {ty("LimitExceeded")} }} {kw("from")} {st_("&quot;./errors&quot;")};',
        '',
        cm('// Daily outbound limit per account, in minor units.'),
        cm('// Spec: .dante/specs/transfer-limits.md §2'),
        f'{kw("export const")} DEFAULT_DAILY_LIMIT = {fn("minor")}({nu("500_000")});',
        '',
        f'{kw("export async function")} {fn("checkDailyLimit")}(',
        f'  accountId: {ty("string")},',
        f'  amount: {ty("Money")},',
        f'): {ty("Promise")}&lt;{ty("void")}&gt; {{',
        f'  {kw("const")} since = {squig}({kw("new")} {ty("Date")}());',
        f'  {kw("const")} sent = {kw("await")} db.transfers.{fn("sumOutbound")}(accountId, since);',
        f'  {kw("const")} limit = {kw("await")} db.limits.{fn("forAccount")}(accountId) ?? DEFAULT_DAILY_LIMIT;',
        '',
        f'  {kw("if")} (sent.{fn("plus")}(amount).{fn("greaterThan")}(limit)) {{',
        f'    {kw("throw new")} {ty("LimitExceeded")}(accountId, limit, sent);',
        '  }',
        '}',
    ]
    code_rows = []
    for i, l in enumerate(lines, 1):
        bg = f"background: {HL}; " if i == 13 else ""
        code_rows.append(f'<div style="display: flex; {bg}"><span style="width: 44px; flex: 0 0 auto; text-align: right; padding-right: 16px; color: {LN_ACT if i == 13 else LN}">{i}</span><span style="white-space: pre">{l}</span></div>')
    popover = (f'<div style="position: absolute; left: 168px; top: 302px; width: 380px; box-sizing: border-box; background: {RAISED}; border: 1px solid {LINE2}; border-radius: 10px; '
               f'box-shadow: {SHADOW_L}; padding: 12px 14px; display: flex; flex-direction: column; gap: 10px; font-family: {SANS}; font-size: 12.5px">'
               f'<div style="display: flex; gap: 8px; align-items: flex-start">{dot(RED, 7)}<span style="color: {TX}">Cannot find name <span style="font-family: {MONO}">startOfDayUtc</span>.</span><span style="margin-left: auto; color: {TX3}; font-family: {MONO}; font-size: 11px">ts(2304)</span></div>'
               f'<div style="display: flex; gap: 6px; flex-wrap: wrap">{btn("Import from ./time")}{btn("Ask Claude")}</div></div>')
    editor_code = (f'<div style="position: relative; flex: 1 1 auto; padding: 14px 0; font-family: {MONO}; font-size: 13px; line-height: 22px; color: {TX}; background: {CODE_BG}; overflow: auto">'
                   + "".join(code_rows) + popover + '</div>')

    tabs = (f'<div role="tablist" aria-label="Open files" style="display: flex; background: {PANEL}; border-bottom: 1px solid {LINE}; overflow-x: auto">'
            + f'<button type="button" role="tab" aria-selected="true" style="display: flex; align-items: center; gap: 8px; padding: 0 14px; height: 38px; border: 0; border-right: 1px solid {LINE}; background: {CODE_BG}; color: {TX}; font-size: 12.5px; box-shadow: inset 0 2px 0 {ACC}">limits.ts{dot(TX2, 6)}</button>'
            + "".join(f'<button type="button" role="tab" aria-selected="false" style="display: flex; align-items: center; padding: 0 14px; height: 38px; border: 0; border-right: 1px solid {LINE}; background: transparent; color: {TX3}; font-size: 12.5px">{t}</button>' for t in ["transfer.ts", "limits.test.ts", "transfer-limits.md"])
            + '</div>')
    crumbs = (f'<div style="display: flex; align-items: center; gap: 6px; padding: 0 16px; height: 30px; color: {TX3}; font-size: 12px; border-bottom: 1px solid {LINE}; background: {CODE_BG}">'
              f'src{ic("chev", 11)}ledger{ic("chev", 11)}<span style="color: {TX2}">limits.ts</span>{ic("chev", 11)}<span style="color: {TX2}">checkDailyLimit</span>'
              f'<span style="margin-left: auto; display: flex; gap: 6px; align-items: center">{ic("link", 12)}LED-42 · spec §2</span></div>')

    term_lines = [
        f'<span style="color: {TX3}">~/Work/ledger-api</span> <span style="color: {ACC}">❯</span> pnpm test ledger/limits',
        '',
        f'<span style="background: {GRN_BG}; color: {GRN}; padding: 0 4px">PASS</span>  test/ledger/limits.test.ts',
        f'  <span style="color: {GRN}">✓</span> allows a transfer under the daily limit <span style="color: {TX3}">(4 ms)</span>',
        f'  <span style="color: {GRN}">✓</span> rejects a transfer that crosses the limit <span style="color: {TX3}">(3 ms)</span>',
        f'  <span style="color: {GRN}">✓</span> resets at 00:00 UTC <span style="color: {TX3}">(2 ms)</span>',
        f'  <span style="color: {GRN}">✓</span> uses the per-account override when set <span style="color: {TX3}">(3 ms)</span>',
        f'  <span style="color: {RED}">✗</span> concurrent transfers cannot both pass the limit <span style="color: {TX3}">(41 ms)</span>',
        '',
        f'Tests: <span style="color: {RED}">1 failed</span>, <span style="color: {GRN}">4 passed</span>, 5 total',
    ]
    term_tabs = "".join(
        f'<button type="button" style="border: 0; background: {RAISED if i == 0 else "transparent"}; color: {TX if i == 0 else TX3}; padding: 4px 10px; border-radius: 6px; font-size: 12px; display: flex; align-items: center; gap: 6px">{ic("term", 12)}{t}</button>'
        for i, t in enumerate(["zsh", "test:watch", "compose logs"]))
    terminal = (f'<section aria-label="Terminal" style="flex: 0 0 auto; border-top: 1px solid {LINE}; background: {PANEL}; display: flex; flex-direction: column">'
                f'<div style="display: flex; align-items: center; gap: 4px; padding: 6px 10px; border-bottom: 1px solid {LINE}">{term_tabs}'
                f'<button type="button" aria-label="New terminal" style="margin-left: auto; border: 0; background: transparent; color: {TX3}; width: 28px; height: 28px; display: flex; align-items: center; justify-content: center">{ic("plus", 14)}</button></div>'
                f'<div style="padding: 10px 16px 14px; font-family: {MONO}; font-size: 12.5px; line-height: 20px; color: {TX2}">'
                + "".join(f'<div style="white-space: pre">{l if l else " "}</div>' for l in term_lines) + '</div></section>')

    status = (f'<footer style="display: flex; flex-wrap: wrap; align-items: center; gap: 16px; padding: 0 14px; min-height: 26px; background: {PANEL}; border-top: 1px solid {LINE}; color: {TX3}; font-size: 11.5px">'
              f'<span style="display: flex; align-items: center; gap: 5px">{ic("branch", 12)}feat/transfer-limits</span>'
              f'<span style="display: flex; align-items: center; gap: 5px">{dot(GRN, 6)}TypeScript LSP</span>'
              f'<span style="display: flex; align-items: center; gap: 5px; color: {RED}">{dot(RED, 6)}1 error</span>'
              f'<span style="margin-left: auto">Ln 13, Col 17</span><span>UTF-8</span><span>Spaces: 2</span></footer>')

    def tree(depth, label, icon="file", active=False, badge="", bcol=None, open_=False):
        pad = 10 + depth * 14
        bg = f"background: {ACC_BG}; color: {TX};" if active else f"color: {TX2};"
        ico = ic("chevd" if open_ else "chev", 11, TX3) + ic("folder", 14, TX3) if icon == "folder" else f'<span style="width: 11px"></span>' + ic("file", 14, TX3)
        b = f'<span style="margin-left: auto; font-family: {MONO}; font-size: 11px; color: {bcol or GRN}">{badge}</span>' if badge else ""
        return f'<li><a href="Build.dc.html" style="display: flex; align-items: center; gap: 6px; padding: 4px 10px 4px {pad}px; border-radius: 6px; font-size: 12.5px; {bg}">{ico}<span>{label}</span>{b}</a></li>'
    files = (tree(0, "src", "folder", open_=True) + tree(1, "gateway", "folder") + tree(1, "ledger", "folder", open_=True)
             + tree(2, "balance.ts") + tree(2, "limits.ts", active=True, badge="A") + tree(2, "transfer.ts", badge="M", bcol=AMB)
             + tree(1, "worker", "folder") + tree(0, "test", "folder", open_=True) + tree(1, "ledger", "folder", open_=True)
             + tree(2, "limits.test.ts", badge="A") + tree(0, "migrations", "folder") + tree(0, ".dante", "folder")
             + tree(0, "docker-compose.yml") + tree(0, "openapi.yaml") + tree(0, "package.json"))
    explorer = f'''<aside aria-label="Explorer" style="flex: 0 0 248px; box-sizing: border-box; background: {PANEL}; border-right: 1px solid {LINE}; display: flex; flex-direction: column; gap: 14px; padding: 14px 8px">
<a href="Plan.dc.html" style="display: flex; flex-direction: column; gap: 4px; padding: 10px 12px; margin: 0 2px; border-radius: 10px; background: {CARD}; border: 1px solid {LINE}; color: {TX}">
<span style="display: flex; align-items: center; gap: 6px; font-size: 11px; color: {TX3}"><span style="font-family: {MONO}">LED-42</span>·<span style="color: {ACC}">In progress</span></span>
<span style="font-weight: 500">Enforce daily transfer limits</span>
<span style="font-size: 11.5px; color: {TX3}">4 of 5 acceptance tests pass</span></a>
<div style="padding: 0 10px">{eyebrow("Explorer")}</div>
{ul(files, 1)}
</aside>'''

    editor = f'''<section aria-label="Editor" style="flex: 999 1 480px; min-width: 0; display: flex; flex-direction: column">
{tabs}
{crumbs}
{editor_code}
{terminal}
{status}
</section>'''

    def bubble_user(t):
        return f'<div style="align-self: flex-end; max-width: 88%; background: {RAISED}; border: 1px solid {LINE}; border-radius: 12px 12px 4px 12px; padding: 10px 12px; color: {TX}">{t}</div>'
    diffline = lambda sign, t, col, bg: f'<div style="white-space: pre; background: {bg}; padding: 0 10px"><span style="color: {col}">{sign}</span> {t}</div>'
    proposal = (f'<div style="border: 1px solid {LINE2}; border-radius: 10px; overflow: hidden; background: {CODE_BG}">'
                f'<div style="display: flex; align-items: center; gap: 8px; padding: 8px 10px; border-bottom: 1px solid {LINE}; font-size: 12px">{ic("file", 13, TX3)}<span style="font-family: {MONO}">transfer.ts</span>'
                f'<span style="margin-left: auto; font-family: {MONO}; color: {GRN}">+2</span><span style="font-family: {MONO}; color: {RED}">−1</span></div>'
                f'<div style="font-family: {MONO}; font-size: 11.5px; line-height: 19px; padding: 6px 0; color: {TX2}">'
                + diffline("−", "await checkDailyLimit(from, amount);", RED, DEL_BG)
                + diffline(" ", "return db.tx(async (tx) =&gt; {", TX3, "transparent")
                + diffline(" ", "  await tx.lockAccount(from);", TX3, "transparent")
                + diffline("+", "  // limit check must run inside the lock (ADR-010)", GRN, ADD_BG)
                + diffline("+", "  await checkDailyLimit(from, amount, tx);", GRN, ADD_BG)
                + '</div>'
                f'<div style="display: flex; gap: 6px; padding: 8px 10px; border-top: 1px solid {LINE}">{btn("Apply and rerun tests", True)}{btn("Review")}</div></div>')
    agent = f'''<aside aria-label="Claude" style="flex: 1 1 340px; max-width: 100%; box-sizing: border-box; background: {PANEL}; border-left: 1px solid {LINE}; display: flex; flex-direction: column">
<div style="display: flex; align-items: center; gap: 10px; padding: 12px 16px; border-bottom: 1px solid {LINE}">
<span style="font-weight: 600">Claude</span><span style="color: {TX3}">on</span><span style="font-family: {MONO}; font-size: 12px">LED-42</span>
<span style="margin-left: auto">{chip(dot(ACC, 6) + "Proposes, you apply", ACC, ACC_BG, ACC_LINE)}</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 6px; padding: 10px 16px; border-bottom: 1px solid {LINE}">
<span style="font-size: 11.5px; color: {TX3}; width: 100%">Context</span>
{mono_chip("transfer-limits.md")}{mono_chip("ADR-010")}{mono_chip("limits.ts")}{mono_chip("transfer.ts")}{mono_chip("+ Build phase")}</div>
<div style="flex: 1 1 auto; display: flex; flex-direction: column; gap: 14px; padding: 16px; overflow: auto">
{bubble_user("Implement the daily limit from the spec and generate tests for it.")}
<div style="display: flex; flex-direction: column; gap: 10px; color: {TX2}; text-wrap: pretty">
<p style="margin: 0">I added <span style="font-family: {MONO}; font-size: 12px; color: {TX}">checkDailyLimit</span> and generated 5 tests from the acceptance criteria in §3 of the spec.</p>
<p style="margin: 0">One fails. Two concurrent transfers can both pass the check, because it runs <b style="color: {TX}; font-weight: 500">before</b> the per-account lock that ADR-010 requires. Moving it inside the lock fixes this:</p>
</div>
{proposal}
<div style="display: flex; gap: 8px; align-items: flex-start; padding: 10px 12px; border-radius: 10px; background: {WARN_BG}; border: 1px solid {WARN_LINE}; color: {TX2}; font-size: 12px">{ic("alert", 14, AMB)}<span>Build rules: Claude asks before touching <span style="font-family: {MONO}">migrations/</span>. Nothing there is proposed.</span></div>
</div>
<div style="padding: 12px 14px; border-top: 1px solid {LINE}; display: flex; flex-direction: column; gap: 8px">
<label for="ask" style="font-size: 11.5px; color: {TX3}">Message Claude</label>
<div style="display: flex; gap: 8px; align-items: flex-end; padding: 8px 8px 8px 12px; border-radius: 10px; background: {CARD}; border: 1px solid {LINE2}">
<textarea id="ask" rows="2" placeholder="Ask, or type / for phase actions" style="flex: 1 1 auto; resize: none; background: transparent; border: 0; outline: none; color: {TX}; font: inherit; font-size: 13px"></textarea>
<button type="button" aria-label="Send" style="width: 32px; height: 32px; border-radius: 8px; border: 0; background: {ACC}; color: {ON_ACC}; display: flex; align-items: center; justify-content: center">{ic("send", 15)}</button></div>
</div>
</aside>'''
    return explorer + editor + agent

def build():
    page("Build.dc.html", "Code workspace", "Build.dc.html", build_parts())

def palette():
    def item(icon, title, sub, key="", on=False, href="Build.dc.html"):
        bg = f"background: {ACC_BG};" if on else ""
        k = f'<span style="font-family: {MONO}; font-size: 11px; color: {TX3}">{key}</span>' if key else ""
        return (f'<li><a href="{href}" style="display: flex; align-items: center; gap: 12px; padding: 9px 12px; border-radius: 8px; color: {TX}; {bg}">'
                f'<span style="width: 28px; height: 28px; border-radius: 7px; background: {RAISED}; border: 1px solid {LINE}; display: flex; align-items: center; justify-content: center; color: {ACC if on else TX2}">{ic(icon, 15)}</span>'
                f'<span style="flex: 1 1 auto; display: flex; flex-direction: column"><span>{title}</span><span style="font-size: 11.5px; color: {TX3}">{sub}</span></span>{k}</a></li>')
    def group(name, inner):
        return f'<div style="display: flex; flex-direction: column; gap: 2px"><div style="padding: 6px 12px 4px">{eyebrow(name)}</div>{ul(inner, 1)}</div>'
    dialog = f'''<div style="position: absolute; inset: 0; background: {SCRIM}; display: flex; justify-content: center; align-items: flex-start; padding: 96px 16px 16px; box-sizing: border-box">
<div role="dialog" aria-label="Command palette" style="width: 100%; max-width: 660px; background: {CARD}; border: 1px solid {LINE2}; border-radius: 16px; box-shadow: {SHADOW_L}, 0 40px 120px rgba(0, 0, 0, 0.35); overflow: hidden">
<div style="display: flex; align-items: center; gap: 12px; padding: 14px 18px; border-bottom: 1px solid {LINE}">{ic("search", 18, TX3)}
<label for="cmd" style="position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0)">Search or ask</label>
<input id="cmd" value="limit" style="flex: 1 1 auto; background: transparent; border: 0; outline: none; color: {TX}; font: inherit; font-size: 16px">
{chip("All", TX, RAISED, LINE2)}{chip("Code")}{chip("Docs")}{chip("Tasks")}</div>
<div style="padding: 8px; display: flex; flex-direction: column; gap: 6px; max-height: 520px; overflow: auto">
{group("Ask Claude", item("chat", "Ask: “Why can two transfers both pass the limit?”", "Uses LED-42, ADR-010 and the Create transfer flow", "↵", True))}
{group("Code", item("code", "checkDailyLimit", "src/ledger/limits.ts:9 · function", "⌘↵") + item("file", "limits.test.ts", "test/ledger · 5 tests, 1 failing"))}
{group("Docs and tasks", item("paper", "Transfer limits", "specs/transfer-limits.md · Accepted", "", href="Spec.paper.dc.html") + item("plan", "LED-42 Enforce daily transfer limits", "Build · in progress", "", href="Plan.dc.html") + item("flow", "Step 4 · sum outbound today", "Flow: Create transfer", "", href="Flow.dc.html"))}
{group("Actions", item("flask", "Run tests matching “limit”", "5 tests in 1 file") + item("sun", "Theme: Light, Dark or Paper", "Currently Dark", "⌥⌘T", href="Themes.dc.html"))}
</div>
<div style="display: flex; gap: 16px; padding: 10px 18px; border-top: 1px solid {LINE}; color: {TX3}; font-size: 11.5px">
<span>↑↓ move</span><span>↵ open</span><span>⌘↵ open beside</span><span>Tab ask Claude instead</span></div>
</div>
</div>'''
    page("Palette.dc.html", "Command palette", "Build.dc.html", build_parts(), overlay=dialog)

# ======================================================================
# Plan
# ======================================================================
def plan():
    def ph(i, name, state):
        on = i == 3
        if state == "done":
            mark = ic("check", 13, GRN, 2.5); meta = f'<span style="color: {TX3}; font-size: 11.5px">Done</span>'
        elif on:
            mark = dot(ACC, 8); meta = f'<span style="color: {ACC}; font-size: 11.5px; font-family: {MONO}">4/7</span>'
        else:
            mark = dot(LINE2, 8); meta = f'<span style="color: {TX3}; font-size: 11.5px">Planned</span>'
        bg = f"background: {ACC_BG}; color: {TX};" if on else f"color: {TX2};"
        cur = ' aria-current="step"' if on else ""
        return (f'<li><a href="Plan.dc.html"{cur} style="display: flex; align-items: center; gap: 10px; padding: 9px 12px; border-radius: 8px; {bg}">'
                f'<span style="width: 14px; display: flex; justify-content: center">{mark}</span><span style="font-family: {MONO}; font-size: 11px; color: {TX3}">0{i+1}</span>'
                f'<span style="flex: 1 1 auto; font-weight: {600 if on else 400}">{name}</span>{meta}</a></li>')
    plist = "".join(ph(i, p, "done" if i < 3 else ("cur" if i == 3 else "todo")) for i, p in enumerate(PHASES))
    side = f'''<aside aria-label="Phases" style="flex: 0 0 252px; box-sizing: border-box; padding: 24px 12px; background: {PANEL}; border-right: 1px solid {LINE}; display: flex; flex-direction: column; gap: 14px">
<div style="padding: 0 12px">{eyebrow("Lifecycle · service template")}</div>
<ol style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px">{plist}</ol>
<div style="margin: 8px 12px 0; padding-top: 14px; border-top: 1px solid {LINE}; display: flex; flex-direction: column; gap: 8px">
<span style="color: {TX3}; font-size: 12px">Phases organise work, docs and Claude’s context. They never lock you out: work on anything, any time.</span>
{btn("Edit lifecycle", icon="sliders", href="ProjectFormat.dc.html")}</div>
</aside>'''

    entry = card(card_head("Ready to start when", f'<span style="color: {GRN}; font-size: 12px">3/3</span>')
                 + ul(crit(True, "Design phase done") + crit(True, "Specs linked to every Build task") + crit(True, "Local environment boots"), 10))
    exitc = card(card_head("Done when", f'<span style="color: {TX3}; font-size: 12px; font-family: {MONO}">4/7</span>')
                 + ul(crit(True, "API contract frozen") + crit(True, "Migrations reviewed") + crit(False, "Coverage ≥ 80% on ledger-core", "71%")
                      + crit(False, "All Build tasks done", "4 open") + f'<li style="color: {TX3}; font-size: 12px; padding-left: 28px">+ 3 more</li>', 10))
    def rule(label, col, paths):
        return (f'<div style="display: flex; gap: 10px; align-items: baseline"><span style="width: 74px; flex: 0 0 auto; font-size: 12px; color: {col}; font-weight: 500">{label}</span>'
                f'<span style="display: flex; flex-wrap: wrap; gap: 5px">{"".join(mono_chip(p) for p in paths)}</span></div>')
    rules = card(card_head("What Claude may propose here", f'<a href="ProjectFormat.dc.html" style="font-size: 12px">agent.md</a>')
                 + rule("Changes to", GRN, ["src/", "test/", "docs/"]) + rule("Flag first", AMB, ["migrations/", "infra/", "package.json"])
                 + rule("Never", RED, [".env*", "secrets/"])
                 + f'<div style="color: {TX2}; font-size: 12.5px; padding-top: 10px; border-top: 1px solid {LINE}">You apply every change. Each one links to a task, and new branches in code come with a test.</div>')

    def tcard(id_, title, spec, who, extra="", active=False):
        b = f"1px solid {ACC_LINE}" if active else f"1px solid {LINE}"
        return (f'<li><a href="Build.dc.html" style="display: flex; flex-direction: column; gap: 8px; padding: 12px; border-radius: 10px; background: {CARD}; border: {b}; color: {TX}">'
                f'<span style="display: flex; justify-content: space-between; font-family: {MONO}; font-size: 11px; color: {TX3}"><span>{id_}</span><span>{who}</span></span>'
                f'<span style="font-weight: 500; text-wrap: pretty">{title}</span>'
                f'<span style="display: flex; flex-wrap: wrap; gap: 6px; align-items: center">{mono_chip(spec) if spec else ""}{extra}</span></a></li>')
    def col(name, count, items):
        return (f'<div style="display: flex; flex-direction: column; gap: 10px; min-width: 0">'
                f'<div style="display: flex; align-items: center; gap: 8px; padding: 0 2px"><span style="font-weight: 600">{name}</span><span style="color: {TX3}; font-family: {MONO}; font-size: 11.5px">{count}</span></div>'
                f'{ul(items, 8)}</div>')
    small = lambda t, c: f'<span style="font-size: 11.5px; color: {c}">{t}</span>'
    board = (f'<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min(220px, 100%), 1fr)); gap: 16px">'
             + col("Ready", 2, tcard("LED-48", "Idempotency keys on POST /transfers", "idempotency.md", "")
                   + tcard("LED-53", "Rate-limit the balance endpoint", "transfer-limits.md §5", ""))
             + col("In progress", 2, tcard("LED-42", "Enforce daily transfer limits", "transfer-limits.md", "with Claude", small("4/5 tests pass", AMB), True)
                   + tcard("LED-51", "Balance query p95 above 120 ms", "", "", small("missing index found", AMB)))
             + col("Review", 1, tcard("LED-39", "Seed data for staging", "", "", small("PR #88", TX2)))
             + col("Done", 3, tcard("LED-37", "Money as integer minor units", "ADR-011", "")
                   + tcard("LED-35", "Transfer API skeleton", "", "") + tcard("LED-33", "Postgres schema v1", "", "with Claude"))
             + '</div>')

    tabs = (f'<div role="tablist" aria-label="Phase views" style="display: flex; gap: 4px; border-bottom: 1px solid {LINE}">'
            + "".join(f'<button type="button" role="tab" aria-selected="{"true" if t == "Overview" else "false"}" style="border: 0; background: transparent; padding: 10px 12px; font-size: 13px; '
                      + (f'color: {TX}; box-shadow: inset 0 -2px 0 {ACC}; font-weight: 500' if t == "Overview" else f'color: {TX3}') + f'">{t}</button>'
                      for t in ["Overview", "Definition", "Docs", "History"]) + '</div>')

    main = f'''<main style="{MAIN_COL}">
{page_header("Phase 04 of 7", "Build", "Turn the agreed design into working, reviewed code. Started Aug 4. The checklist shows what’s left; move to Test whenever you’re ready.",
             btn("New task", icon="plus") + btn("Move to Test", True))}
{tabs}
{grid(280, entry + exitc + rules)}
<div style="display: flex; align-items: center; justify-content: space-between; gap: 12px"><h2 style="margin: 0; font-size: 15px; font-weight: 600">Tasks</h2>
<div style="display: flex; gap: 8px; flex-wrap: wrap">{chip("Phase: Build")}{chip(ic("file", 12) + ".dante/tasks.yaml")}</div></div>
{board}
</main>'''
    page("Plan.dc.html", "Phases and tasks", "Plan.dc.html", side + main)

# ======================================================================
# Test
# ======================================================================
def test():
    def bar(name, pct, target=80):
        col = GRN if pct >= target else AMB
        return (f'<li style="display: flex; flex-direction: column; gap: 6px">'
                f'<div style="display: flex; justify-content: space-between"><span style="font-family: {MONO}; font-size: 12px">{name}</span>'
                f'<span style="font-family: {MONO}; font-size: 12px; color: {col}">{pct}%</span></div>'
                f'<div style="position: relative; height: 6px; border-radius: 3px; background: {TRACK}">'
                f'<div style="width: {pct}%; height: 6px; border-radius: 3px; background: {col}"></div>'
                f'<div aria-hidden="true" style="position: absolute; left: {target}%; top: -3px; width: 2px; height: 12px; background: {TX2}; border-radius: 1px"></div></div></li>')
    cov = card(card_head("Coverage by component", f'<span style="color: {TX3}; font-size: 12px">target 80%</span>')
               + ul(bar("money", 96) + bar("api-gateway", 84) + bar("ledger-core", 71) + bar("db", 63) + bar("notification-worker", 52), 14))

    def run(name, where, result, col, t):
        return li_row(f'{dot(col, 7)}<div style="flex: 1 1 auto; display: flex; flex-direction: column; gap: 2px"><span style="font-weight: 500">{name}</span><span style="color: {TX3}; font-size: 12px">{where}</span></div>'
                      f'<span style="font-size: 12.5px; color: {col}">{result}</span><span style="font-family: {MONO}; font-size: 11.5px; color: {TX3}; width: 52px; text-align: right">{t}</span>')
    runs = card(card_head("Latest runs", btn("Run all", icon="play"))
                + ul(run("Unit", "local · watch mode", "412 passed · 1 failed", RED, "38s")
                     + run("Integration", "against local compose: postgres, redis", "61 passed", GRN, "2m 10s")
                     + run("Contract", "openapi.yaml v1.3 against the gateway", "24 passed", GRN, "9s")
                     + run("End to end", "not set up yet; planned for the Test phase", "—", TX3, "")))

    def sug(file_, why, src):
        return (f'<li style="display: flex; gap: 12px; align-items: flex-start; padding: 12px 0; border-top: 1px solid {LINE}">'
                f'<input type="checkbox" checked aria-label="Include {file_}" style="margin-top: 3px; accent-color: {ACC}">'
                f'<div style="flex: 1 1 auto; display: flex; flex-direction: column; gap: 3px; min-width: 0"><span style="font-family: {MONO}; font-size: 12px; color: {TX}">{file_}</span>'
                f'<span style="color: {TX2}">{why}</span><span style="font-size: 11.5px; color: {TX3}">{src}</span></div>{btn("Preview")}</li>')
    gen = card(card_head("Tests Claude can draft", f'<span style="color: {TX3}; font-size: 12px">from specs and untested branches</span>')
               + ul(sug("transfer.test.ts", "Zero and negative amounts are rejected", "Spec transfer-limits.md §2.3 · no matching test")
                    + sug("balance.test.ts", "Currency mismatch returns 422", "Untested branch · balance.ts:48")
                    + sug("receipts.test.ts", "Retries after an SMTP 4xx, gives up after 5", "Untested branch · worker/receipts.ts:31"))
               + row(f'<span style="color: {TX3}; font-size: 12px">3 selected · you review each file before it’s written</span>', btn("Draft 3 tests", True)))

    def ac(id_, text, tests, status, col):
        return (f'<tr style="border-top: 1px solid {LINE}"><td style="padding: 10px 12px 10px 0; font-family: {MONO}; font-size: 12px; color: {TX3}">{id_}</td>'
                f'<td style="padding: 10px 12px 10px 0">{text}</td><td style="padding: 10px 12px 10px 0; font-family: {MONO}; font-size: 12px; color: {TX2}">{tests}</td>'
                f'<td style="padding: 10px 0; white-space: nowrap"><span style="display: inline-flex; align-items: center; gap: 6px; color: {col}; font-size: 12.5px">{dot(col, 6)}{status}</span></td></tr>')
    th = f'style="text-align: left; font-weight: 500; font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: {TX3}; padding: 0 12px 8px 0"'
    trace = card(card_head("Acceptance criteria · transfer-limits.md", '<a href="Spec.paper.dc.html" style="font-size: 12px">Open spec</a>')
                 + f'<div style="overflow-x: auto"><table style="width: 100%; border-collapse: collapse; font-size: 13px; min-width: 520px"><thead><tr><th {th}>ID</th><th {th}>Criterion</th><th {th}>Tests</th><th {th}>Status</th></tr></thead><tbody>'
                 + ac("AC-1", "Transfers under the daily limit go through", "2", "Passing", GRN)
                 + ac("AC-2", "A transfer that crosses the limit is rejected with 409", "1", "Passing", GRN)
                 + ac("AC-3", "The limit resets at 00:00 UTC", "1", "Passing", GRN)
                 + ac("AC-4", "Concurrent transfers cannot exceed the limit together", "1", "Failing", RED)
                 + ac("AC-5", "Each rejection writes an audit entry", "0", "No tests", AMB)
                 + '</tbody></table></div>', "grid-column: 1 / -1")

    main = f'''<main style="{MAIN_COL}">
{page_header("Quality", "Tests", "Each test traces back to a spec or a code path. Gaps show up while you build, so the Test phase starts from a known state.",
             chip(dot(AMB, 6) + "Test checklist: 2 of 5"))}
<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min(400px, 100%), 1fr)); gap: 16px">
{trace}
{gen}
<div style="display: flex; flex-direction: column; gap: 16px">{cov}{runs}</div>
</div>
</main>'''
    page("Test.dc.html", "Tests", "Test.dc.html", main)

# ======================================================================
# Environments
# ======================================================================
def environments():
    def svc(name, image, status, col, port, cpu, mem, up, sel=False):
        b = f"1.5px solid {WARN_BORDER}" if sel else f"1px solid {LINE}"
        return (f'<li style="background: {CARD}; border: {b}; border-radius: 12px; padding: 14px 16px; display: flex; flex-direction: column; gap: 12px; min-width: 0">'
                f'<div style="display: flex; align-items: center; gap: 8px">{dot(col, 8)}<span style="font-weight: 600; font-family: {MONO}; font-size: 13px">{name}</span>'
                f'<span style="margin-left: auto; font-size: 12px; color: {col}">{status}</span></div>'
                f'<div style="font-family: {MONO}; font-size: 11.5px; color: {TX3}">{image}</div>'
                f'<div style="display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; font-size: 12px">'
                f'<div style="display: flex; flex-direction: column; gap: 2px"><span style="color: {TX3}">Port</span><span style="font-family: {MONO}">{port}</span></div>'
                f'<div style="display: flex; flex-direction: column; gap: 2px"><span style="color: {TX3}">CPU / mem</span><span style="font-family: {MONO}">{cpu} · {mem}</span></div>'
                f'<div style="display: flex; flex-direction: column; gap: 2px"><span style="color: {TX3}">Up</span><span style="font-family: {MONO}">{up}</span></div></div>'
                f'<div style="display: flex; gap: 6px; flex-wrap: wrap">{btn("Logs", icon="doc")}{btn("Shell", icon="shell")}{btn("Restart", icon="refresh")}</div></li>')
    services = (f'<ul style="list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fit, minmax(min(250px, 100%), 1fr)); gap: 12px">'
                + svc("notification-worker", "build ./src/worker", "restarting", AMB, "—", "0%", "38 MB", "exit 1 ×3", True)
                + svc("ledger-service", "build ./src/ledger", "running", GRN, ":3001", "2%", "142 MB", "3h 12m")
                + svc("api-gateway", "node:22-alpine", "running", GRN, ":8080", "1%", "88 MB", "3h 12m")
                + svc("postgres", "postgres:16", "healthy", GRN, ":5432", "3%", "210 MB", "3h 12m")
                + svc("redis", "redis:7-alpine", "running", GRN, ":6379", "0%", "12 MB", "3h 12m")
                + '</ul>')

    logs = [
        (None, "14:02:11", "worker", "connecting to nats://localhost:4222"),
        (RED, "14:02:13", "worker", "Error: connect ECONNREFUSED 127.0.0.1:4222"),
        (None, "14:02:13", "worker", "    at TCPConnectWrap.afterConnect (node:net:1607:16)"),
        (AMB, "14:02:13", "docker", "notification-worker exited with code 1, restarting (3)"),
        (None, "14:02:16", "worker", "connecting to nats://localhost:4222"),
        (RED, "14:02:18", "worker", "Error: connect ECONNREFUSED 127.0.0.1:4222"),
    ]
    log_html = "".join(f'<div style="display: flex; gap: 14px; white-space: pre"><span style="color: {LOGT}">{t}</span><span style="color: {TX3}; width: 52px">{src}</span><span style="color: {c or TX2}">{m}</span></div>' for c, t, src, m in logs)
    log_card = (f'<section aria-label="Logs" style="background: {CODE_BG}; border: 1px solid {LINE}; border-radius: 12px; overflow: hidden; display: flex; flex-direction: column">'
                f'<div style="display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-bottom: 1px solid {LINE}; background: {PANEL}">{ic("doc", 14, TX3)}'
                f'<span style="font-family: {MONO}; font-size: 12.5px">notification-worker</span><span style="color: {TX3}; font-size: 12px">following</span>'
                f'<div style="margin-left: auto; display: flex; gap: 6px">{btn("Pause")}{btn("Clear")}</div></div>'
                f'<div style="padding: 12px 14px; font-family: {MONO}; font-size: 12px; line-height: 21px; overflow-x: auto">{log_html}</div></section>')

    fix = (f'<section style="background: {CARD}; border: 1px solid {ACC_LINE}; border-radius: 12px; padding: 16px 18px; display: flex; flex-direction: column; gap: 12px">'
           f'<div style="display: flex; align-items: center; gap: 8px">{ic("chat", 15, ACC)}<span style="font-weight: 600">Claude found the cause</span></div>'
           f'<p style="margin: 0; color: {TX2}; text-wrap: pretty">The worker subscribes to NATS on port 4222, but <span style="font-family: {MONO}; font-size: 12px; color: {TX}">docker-compose.yml</span> has no NATS service. The architecture map flagged the same gap.</p>'
           f'<div style="font-family: {MONO}; font-size: 11.5px; line-height: 19px; border-radius: 8px; background: {CODE_BG}; border: 1px solid {LINE}; padding: 8px 0">'
           + "".join(f'<div style="white-space: pre; padding: 0 12px; background: {ADD_BG}"><span style="color: {GRN}">+</span> {l}</div>' for l in ["  nats:", "    image: nats:2.10-alpine", "    ports: [&quot;4222:4222&quot;]", "    command: [&quot;-js&quot;]"])
           + f'</div><div style="display: flex; gap: 8px; flex-wrap: wrap">{btn("Apply and start NATS", True)}{btn("Edit first")}</div></section>')

    gen_card = card(card_head("Docker files", f'<span style="color: {TX3}; font-size: 12px">Claude writes, you review</span>')
                    + ul(li_row(f'{ic("check", 14, GRN, 2.25)}{mono("docker-compose.yml", TX)}<span style="flex: 1 1 auto; color: {TX3}; font-size: 12px">5 services, 1 profile</span>', False, "6px 0")
                         + li_row(f'{ic("check", 14, GRN, 2.25)}{mono("src/ledger/Dockerfile", TX)}<span style="flex: 1 1 auto; color: {TX3}; font-size: 12px">multi-stage, node:22</span>', False, "6px 0")
                         + li_row(f'{ic("alert", 14, AMB)}{mono("src/worker/Dockerfile", TX)}<span style="flex: 1 1 auto; color: {AMB}; font-size: 12px">missing: compose builds the repo root</span>{btn("Generate")}', False, "6px 0")))

    main = f'''<main style="{MAIN_COL}">
{page_header("Environments", "Local", "Runs docker-compose.yml with the dev profile. Start, stop, rebuild and read logs here, or let Claude write the Docker files a project is missing.",
             seg_group("Environment", ["Local", "Staging"], "Local") + btn("Stop all", icon="stop") + btn("Rebuild", icon="refresh"))}
<div style="display: flex; flex-wrap: wrap; gap: 8px; align-items: center">{chip(ic("box", 13) + "compose: docker-compose.yml")}{chip("profile: dev")}{chip("seed: staging-lite")}<span style="margin-left: auto; color: {TX3}; font-size: 12px">Docker Desktop · 4 of 5 services up</span></div>
{services}
<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min(400px, 100%), 1fr)); gap: 16px">
{log_card}
<div style="display: flex; flex-direction: column; gap: 16px">{fix}{gen_card}</div>
</div>
</main>'''
    page("Environments.dc.html", "Environments", "Environments.dc.html", main)

# ======================================================================
# Release
# ======================================================================
def release():
    chk = card(card_head("Release checklist", mono("4/6", TX3))
               + ul(crit(True, "Version: 0.4.0 (minor, new behaviour)") + crit(True, "Changelog drafted") + crit(True, "Migrations are reversible")
                    + crit(True, "openapi.yaml version bumped") + crit(False, "Test checklist", "2/5") + crit(False, "CI green on the release branch", "1 failing"), 10)
               + f'<div style="color: {TX3}; font-size: 12px; padding-top: 10px; border-top: 1px solid {LINE}">A guide, not a gate. You can tag whenever you choose.</div>')

    def cl(head, items):
        lis = "".join(f'<li style="display: flex; gap: 8px; align-items: baseline"><span style="color: {TX3}">–</span><span style="flex: 1 1 auto">{t}</span>{mono_chip(ref)}</li>' for t, ref in items)
        return f'<div style="display: flex; flex-direction: column; gap: 8px"><h3 style="margin: 0; font-size: 12px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: {TX3}">{head}</h3>{ul(lis, 6)}</div>'
    changelog = card(card_head("Changelog · 0.4.0", f'<div style="display: flex; gap: 6px">{btn("Edit")}{btn("Copy", icon="doc")}</div>')
                     + f'<div style="color: {TX3}; font-size: 12px">Drafted from 9 tasks and 34 commits since v0.3.2. Internal refactors are left out.</div>'
                     + cl("Added", [("Daily outbound transfer limit per account", "LED-42"), ("Per-account limit overrides", "LED-42"), ("Idempotency keys on POST /transfers", "LED-48")])
                     + cl("Changed", [("Money is stored as integer minor units", "ADR-011")])
                     + cl("Fixed", [("Staging seed data no longer duplicates accounts", "LED-39")]))

    def stage(name, state, col, t, icon):
        return (f'<li style="flex: 1 1 120px; min-width: 0; display: flex; flex-direction: column; gap: 6px; padding: 12px; border-radius: 10px; background: {RAISED}; border: 1px solid {LINE if col != RED else WARN_BORDER}">'
                f'<span style="display: flex; align-items: center; gap: 6px; color: {col}; font-size: 12px">{ic(icon, 13, col, 2.25)}{state}</span>'
                f'<span style="font-weight: 500">{name}</span><span style="font-family: {MONO}; font-size: 11.5px; color: {TX3}">{t}</span></li>')
    pipeline = card(card_head("CI · GitHub Actions · ci.yml", f'<a href="Build.dc.html" style="font-size: 12px">Run #214 · feat/transfer-limits</a>')
                    + f'<ol style="list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 8px">'
                    + stage("Lint", "passed", GRN, "18s", "check") + stage("Unit tests", "failed", RED, "41s", "x")
                    + stage("Integration", "skipped", TX3, "—", "chev") + stage("Build image", "skipped", TX3, "—", "chev") + stage("Deploy staging", "waiting", TX3, "—", "chev")
                    + '</ol>'
                    + f'<div style="display: flex; gap: 10px; align-items: flex-start; padding: 12px; border-radius: 10px; background: {WARN_BG}; border: 1px solid {WARN_LINE}">{ic("alert", 15, AMB)}'
                    f'<span style="flex: 1 1 auto; color: {TX2}"><b style="color: {TX}; font-weight: 500">concurrent transfers cannot both pass the limit</b> fails in CI too. Claude has a fix ready in LED-42.</span>{btn("Open fix", href="Build.dc.html")}</div>'
                    + ul(li_row(f'{dot(GRN, 7)}<span style="flex: 1 1 auto">main · run #211</span><span style="color: {TX3}; font-size: 12px">deployed to staging 2 days ago</span>{mono("6m 02s", TX3)}')))

    main = f'''<main style="{MAIN_COL}">
{page_header("Release", "v0.4.0", "What shipping today would include. Dante drafts the version, the changelog and the tag from your tasks and commits; you decide when.",
             btn("Copy changelog", icon="doc") + btn("Tag v0.4.0", True, "tag"))}
{pipeline}
<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min(380px, 100%), 1fr)); gap: 16px">
{changelog}
{chk}
</div>
</main>'''
    page("Release.dc.html", "Release", "Release.dc.html", main)

# ======================================================================
# Operate
# ======================================================================
def spark(points, col, w=260, h=56):
    mx = max(points); mn = min(points)
    step = w / (len(points) - 1)
    pts = " ".join(f"{i * step:.1f},{h - 4 - (p - mn) / (mx - mn or 1) * (h - 8):.1f}" for i, p in enumerate(points))
    return (f'<svg aria-hidden="true" viewBox="0 0 {w} {h}" preserveAspectRatio="none" style="width: 100%; height: {h}px; display: block">'
            f'<polyline points="{pts}" fill="none" stroke="{col}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"></polyline></svg>')

def operate():
    def metric(label, val, unit, note, ncol, pts, col):
        return card(f'<div style="display: flex; justify-content: space-between; align-items: baseline"><span style="color: {TX2}">{label}</span><span style="font-size: 12px; color: {ncol}">{note}</span></div>'
                    f'<div style="display: flex; align-items: baseline; gap: 6px"><span style="font-size: 28px; font-weight: 600; letter-spacing: -0.02em; font-family: {MONO}">{val}</span><span style="color: {TX3}">{unit}</span></div>'
                    + spark(pts, col), "gap: 10px")
    metrics = grid(260, metric("Requests", "1.2k", "/ min", "normal", TX3, [9, 10, 12, 11, 13, 12, 14, 13, 12, 11, 12, 13], ACC)
                   + metric("p95 latency", "184", "ms", "target 120 ms", AMB, [96, 98, 102, 101, 140, 152, 160, 171, 168, 176, 182, 184], AMB)
                   + metric("Error rate", "0.4", "%", "normal", TX3, [3, 4, 3, 5, 4, 3, 4, 4, 5, 4, 3, 4], ACC))

    def err(title, where, count, link, col):
        return li_row(f'{dot(col, 7)}<div style="flex: 1 1 auto; display: flex; flex-direction: column; gap: 2px; min-width: 0"><span style="font-family: {MONO}; font-size: 12.5px; color: {TX}">{title}</span><span style="font-size: 12px; color: {TX3}">{where}</span></div>'
                      f'<span style="font-family: {MONO}; font-size: 12px; color: {TX2}; width: 56px; text-align: right">{count}</span><span style="width: 112px; display: flex; justify-content: flex-end">{link}</span>')
    errors = card(card_head("Errors · last 24 h", f'<span style="color: {TX3}; font-size: 12px">CloudWatch Logs · ledger-api</span>')
                  + ul(err("TimeoutError: balance query over 2 s", "src/ledger/balance.ts:31 · ledger-service", "41", f'<a href="Plan.dc.html" style="font-size: 12px">LED-51</a>', AMB)
                       + err("ECONNRESET from SMTP provider", "src/worker/receipts.ts:52 · notification-worker", "12", btn("Create task"), AMB)
                       + err("UnhandledPromiseRejection", "src/worker/receipts.ts:31 · notification-worker", "3", btn("Create task"), RED)))

    def alarm(name, state, col, since):
        return li_row(f'{dot(col, 7)}<span style="flex: 1 1 auto">{name}</span><span style="font-size: 12px; color: {col}">{state}</span><span style="font-family: {MONO}; font-size: 11.5px; color: {TX3}; width: 80px; text-align: right">{since}</span>')
    alarms = card(card_head("Alarms", f'<span style="color: {TX3}; font-size: 12px">3 configured</span>')
                  + ul(alarm("Receipt queue has dead letters", "ALARM", AMB, "since 06:12") + alarm("RDS CPU above 80%", "OK", GRN, "") + alarm("5xx above 1% for 5 min", "OK", GRN, "")))

    claude = (f'<section style="background: {CARD}; border: 1px solid {ACC_LINE}; border-radius: 12px; padding: 16px 18px; display: flex; flex-direction: column; gap: 12px">'
              f'<div style="display: flex; align-items: center; gap: 8px">{ic("chat", 15, ACC)}<span style="font-weight: 600">Why p95 went up</span></div>'
              f'<p style="margin: 0; color: {TX2}; text-wrap: pretty">Latency rose after v0.3.2 shipped on Sep 28. Balance queries scan <span style="font-family: {MONO}; font-size: 12px; color: {TX}">entries</span> without an index on <span style="font-family: {MONO}; font-size: 12px; color: {TX}">account_id</span>, as the data model shows. It’s already tracked as LED-51.</p>'
              f'<div style="display: flex; gap: 8px; flex-wrap: wrap">{btn("Draft migration 0008", True)}{btn("Open data model", href="DataModel.dc.html")}</div>'
              f'<span style="font-size: 12px; color: {TX3}">migrations/ is “flag first” in Build rules, so you’ll see the file before anything changes.</span></section>')

    main = f'''<main style="{MAIN_COL}">
{page_header("Operate · production", "Runtime health", "From CloudWatch metrics, logs and alarms for the ledger-api stack. Every error links back to a task, or can become one.",
             chip(ic("tag", 13) + "v0.3.2 · deployed Sep 28") + seg_group("Range", ["1 h", "24 h", "7 d"], "24 h"))}
{metrics}
<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min(420px, 100%), 1fr)); gap: 16px">
{errors}
<div style="display: flex; flex-direction: column; gap: 16px">{claude}{alarms}</div>
</div>
</main>'''
    page("Operate.dc.html", "Runtime health", "Operate.dc.html", main)

# ======================================================================
# Onboarding
# ======================================================================
def onboarding():
    tb = titlebar(phases=PHASES, cur=-1, env=("compose found", GRN))
    steps = [("Read the repo", "done"), ("Project type", "done"), ("Current phase", "cur"), ("Specs and docs", "todo"), ("Architecture", "todo"), ("Decisions", "todo"), ("Rules for Claude", "todo")]
    def st(i, n, s):
        mark = ic("check", 13, GRN, 2.5) if s == "done" else (dot(ACC, 8) if s == "cur" else dot(LINE2, 8))
        bg = f"background: {ACC_BG}; color: {TX}; font-weight: 600;" if s == "cur" else f"color: {TX2 if s == 'done' else TX3};"
        return f'<li style="display: flex; align-items: center; gap: 10px; padding: 9px 12px; border-radius: 8px; {bg}"><span style="width: 14px; display: flex; justify-content: center">{mark}</span>{n}</li>'
    side = f'''<aside aria-label="Setup steps" style="flex: 0 0 252px; box-sizing: border-box; padding: 24px 12px; background: {PANEL}; border-right: 1px solid {LINE}; display: flex; flex-direction: column; gap: 14px">
<div style="padding: 0 12px">{eyebrow("Setting up ledger-api")}</div>
<ol style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px">{"".join(st(i, n, s) for i, (n, s) in enumerate(steps))}</ol>
<div style="margin: 8px 12px 0; padding-top: 14px; border-top: 1px solid {LINE}; display: flex; flex-direction: column; gap: 6px; color: {TX3}; font-size: 12px">
<span>Read in 48 s</span>{mono("214 files · 412 commits<br>README.md, docs/ (6)<br>docker-compose.yml<br>openapi.yaml, migrations/ (7)", TX2, 11.5)}</div>
</aside>'''

    def proposal(n, title, answer, evidence, state, extra=""):
        if state == "accepted":
            right = f'<span style="display: flex; align-items: center; gap: 6px; color: {GRN}; font-size: 12px">{ic("check", 13, GRN, 2.5)}Accepted</span>'
            b = LINE
        elif state == "active":
            right = f'<div style="display: flex; gap: 6px">{btn("Change")}{btn("Accept", True)}</div>'
            b = ACC_LINE
        else:
            right = f'<span style="color: {TX3}; font-size: 12px">Next</span>'
            b = LINE
        ev = "".join(f'<li style="display: flex; gap: 8px; color: {TX2}; font-size: 12.5px"><span style="color: {TX3}">–</span><span>{e}</span></li>' for e in evidence)
        return (f'<section style="background: {CARD}; border: 1px solid {b}; border-radius: 12px; padding: 16px 18px; display: flex; flex-direction: column; gap: 10px; {"opacity: 0.72;" if state == "todo" else ""}">'
                f'<div style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap"><span style="font-family: {MONO}; font-size: 11.5px; color: {TX3}">0{n}</span>'
                f'<span style="font-weight: 600">{title}</span><span style="color: {TX3}">·</span><span style="color: {ACC}; font-weight: 500">{answer}</span><span style="margin-left: auto">{right}</span></div>'
                + (ul(ev, 4) if evidence else "") + extra + '</section>')

    phase_pick = (f'<div style="display: flex; flex-wrap: wrap; gap: 4px; padding-top: 4px">'
                  + "".join(f'<button type="button" aria-pressed="{"true" if p == "Build" else "false"}" style="padding: 5px 10px; border-radius: 7px; font-size: 12px; '
                            + (f'background: {ACC}; color: {ON_ACC}; border: 1px solid {ACC}; font-weight: 600' if p == "Build" else f'background: transparent; color: {TX2}; border: 1px solid {LINE2}') + f'">{p}</button>' for p in PHASES)
                  + '</div>')

    main = f'''<main style="{MAIN_COL}">
{page_header("New to Dante", "Claude drafted a project spec", "Everything below is a proposal based on what’s already in the repo. Nothing is written until you accept it, and it all stays editable as plain files in .dante/.")}
{proposal(1, "Project type", "Web service · TypeScript, Postgres, Redis, NATS", ["package.json, docker-compose.yml and openapi.yaml", "Lifecycle template: service (7 phases)"], "accepted")}
{proposal(2, "Current phase", "Build", ["38 of the last 40 commits change src/ or test/", "No release tag since v0.3.2 on Sep 28", "docs/limits.md reads like an agreed design, not a draft"], "active", phase_pick)}
{proposal(3, "Specs and docs", "4 found, 2 drafted", ["docs/limits.md becomes specs/transfer-limits.md", "idempotency.md drafted from TODOs and PR #81"], "todo")}
{proposal(4, "Architecture", "8 containers, 2 external", [], "todo")}
{proposal(5, "Decisions", "3 recovered from history", [], "todo")}
</main>'''

    def tree(depth, label, folder=False, badge="A"):
        pad = 12 + depth * 16
        ico = ic("folder", 14, TX3) if folder else ic("file", 14, TX3)
        b = f'<span style="margin-left: auto; font-family: {MONO}; font-size: 11px; color: {GRN}">{badge}</span>' if badge and not folder else ""
        return f'<li style="display: flex; align-items: center; gap: 7px; padding: 4px 10px 4px {pad}px; font-family: {MONO}; font-size: 12px; color: {TX2}">{ico}<span>{label}</span>{b}</li>'
    t = (tree(0, ".dante/", True) + tree(1, "project.yaml") + tree(1, "agent.md") + tree(1, "architecture.md") + tree(1, "phases/", True)
         + tree(2, "7 files") + tree(1, "specs/", True) + tree(2, "transfer-limits.md") + tree(2, "idempotency.md") + tree(2, "+ 4 more")
         + tree(1, "decisions/", True) + tree(2, "ADR-010 … ADR-012") + tree(1, "tasks.yaml"))
    insp = inspector(f'''<div style="display: flex; flex-direction: column; gap: 6px">{eyebrow("Will be written")}<div style="font-size: 18px; font-weight: 600">18 files</div>
<p style="margin: 0; color: {TX2}">Plain markdown and YAML. Review them like any other change.</p></div>
{ul(t, 0)}
<div style="display: flex; gap: 10px; align-items: flex-start; padding-top: 12px; border-top: 1px solid {LINE}">
<input id="claude-md" type="checkbox" checked style="margin-top: 3px; accent-color: {ACC}">
<label for="claude-md" style="color: {TX2}">Also keep <span style="font-family: {MONO}; font-size: 12px; color: {TX}">CLAUDE.md</span> in sync, so other tools see the same rules</label></div>
<div style="display: flex; flex-direction: column; gap: 8px; margin-top: auto">
{btn("Accept all remaining", href="Overview.dc.html")}
{btn("Write 18 files", True, "check", "Overview.dc.html")}
</div>''', "Files")
    page("Onboarding.dc.html", "Project setup", "", side + main + insp, tb=tb)

# ======================================================================
# Project spec (.dante/)
# ======================================================================
def project_format():
    def tree(depth, label, folder=False, active=False, note=""):
        pad = 12 + depth * 16
        bg = f"background: {ACC_BG}; color: {TX};" if active else f"color: {TX2};"
        ico = ic("folder", 14, TX3) if folder else ic("file", 14, TX3)
        n = f'<span style="margin-left: auto; font-size: 11px; color: {TX3}">{note}</span>' if note else ""
        return f'<li><a href="ProjectFormat.dc.html" style="display: flex; align-items: center; gap: 7px; padding: 5px 10px 5px {pad}px; border-radius: 6px; font-family: {MONO}; font-size: 12px; {bg}">{ico}<span>{label}</span>{n}</a></li>'
    t = (tree(0, ".dante/", True) + tree(1, "project.yaml", active=True) + tree(1, "agent.md", note="Claude’s rules")
         + tree(1, "architecture.md", note="your notes") + tree(1, "phases/", True, note="7")
         + tree(2, "discover.md") + tree(2, "define.md") + tree(2, "design.md") + tree(2, "build.md") + tree(2, "test.md") + tree(2, "release.md") + tree(2, "operate.md")
         + tree(1, "specs/", True, note="6") + tree(1, "decisions/", True, note="12") + tree(1, "runbooks/", True, note="1") + tree(1, "tasks.yaml"))
    side = f'''<aside aria-label="Spec files" style="flex: 0 0 260px; box-sizing: border-box; padding: 24px 10px; background: {PANEL}; border-right: 1px solid {LINE}; display: flex; flex-direction: column; gap: 14px">
<div style="padding: 0 12px">{eyebrow("In the repo")}</div>
{ul(t, 1)}
<div style="margin: 6px 12px 0; padding-top: 14px; border-top: 1px solid {LINE}; display: flex; flex-direction: column; gap: 6px; color: {TX3}; font-size: 12px">
<span>Drafted at setup from</span><span style="font-family: {MONO}; color: {TX2}">README.md, CLAUDE.md, docs/ (6), git history</span></div>
</aside>'''

    k = lambda s: f'<span style="color: {ACC}">{s}</span>'
    v = lambda s: f'<span style="color: {S}">{s}</span>'
    c = lambda s: f'<span style="color: {C}">{s}</span>'
    yaml = [
        f'{k("name")}: {v("ledger-api")}',
        f'{k("summary")}: {v("Double-entry ledger for internal payments.")}',
        '',
        f'{k("lifecycle")}:',
        f'  {k("template")}: {v("service@1")}',
        f'  {k("current")}: {v("build")}',
        '',
        f'{k("phases")}:',
        f'  {k("build")}:',
        f'    {k("definition")}: {v("phases/build.md")}',
        f'    {k("done_when")}:   {c("# a checklist, never a gate")}',
        f'      - {k("coverage")}: {{ {k("component")}: {v("ledger-core")}, {k("min")}: {nu("80")} }}',
        f'      - {k("tasks")}: {{ {k("phase")}: {v("build")}, {k("state")}: {v("done")} }}',
        f'      - {k("decision")}: {v("ADR-012")}',
        f'    {k("claude")}:',
        f'      {k("propose")}: [{v("src/")}, {v("test/")}, {v("docs/")}]',
        f'      {k("flag")}:    [{v("migrations/")}, {v("infra/")}]',
        f'      {k("never")}:   [{v("&quot;.env*&quot;")}, {v("secrets/")}]',
        '',
        f'{k("maps")}:',
        f'  {k("architecture")}: [{v("docker-compose.yml")}, {v("&quot;src/**&quot;")}, {v("openapi.yaml")}]',
        f'  {k("data")}: [{v("migrations/")}]',
        f'  {k("cloud")}: [{v("infra/cdk.out")}]',
        '',
        f'{k("environments")}:',
        f'  {k("local")}: {{ {k("compose")}: {v("docker-compose.yml")}, {k("profiles")}: [{v("dev")}] }}',
        f'  {k("production")}: {{ {k("logs")}: {v("cloudwatch")}, {k("stack")}: {v("ledger-api")} }}',
        '',
        f'{k("export")}: [{v("CLAUDE.md")}]   {c("# other tools see the same rules")}',
    ]
    yrows = "".join(f'<div style="display: flex"><span style="width: 40px; flex: 0 0 auto; text-align: right; padding-right: 14px; color: {LN}">{i}</span><span style="white-space: pre">{l}</span></div>' for i, l in enumerate(yaml, 1))
    editor = (f'<section aria-label="project.yaml" style="background: {CODE_BG}; border: 1px solid {LINE}; border-radius: 12px; overflow: hidden; display: flex; flex-direction: column; min-width: 0">'
              f'<div style="display: flex; align-items: center; gap: 8px; padding: 10px 14px; border-bottom: 1px solid {LINE}; background: {PANEL}">{ic("file", 14, TX3)}'
              f'<span style="font-family: {MONO}; font-size: 12.5px">.dante/project.yaml</span><span style="margin-left: auto; display: flex; align-items: center; gap: 6px; color: {GRN}; font-size: 12px">{ic("check", 12, GRN, 2.5)}Schema valid</span></div>'
              f'<div style="padding: 12px 0; font-family: {MONO}; font-size: 12.5px; line-height: 21px; color: {TX}; overflow-x: auto">{yrows}</div></section>')

    def ctxrow(n, label, src, tok):
        return (f'<li style="display: flex; gap: 12px; align-items: flex-start; padding: 10px 0; border-top: 1px solid {LINE}">'
                f'<span style="font-family: {MONO}; font-size: 11.5px; color: {TX3}; width: 18px">{n}</span>'
                f'<div style="flex: 1 1 auto; display: flex; flex-direction: column; gap: 2px; min-width: 0"><span style="font-weight: 500">{label}</span><span style="font-family: {MONO}; font-size: 11.5px; color: {TX3}">{src}</span></div>'
                f'<span style="font-family: {MONO}; font-size: 11.5px; color: {TX2}">{tok}</span></li>')
    preview = card(card_head("What Claude gets for LED-42", f'<span style="font-family: {MONO}; font-size: 12px; color: {TX3}">≈ 8.2k tokens</span>')
                   + f'<p style="margin: 0; color: {TX2}; text-wrap: pretty">Dante assembles this context before each task, in this order. You choose what goes in.</p>'
                   + '<ol style="list-style: none; margin: 0; padding: 0">'
                   + ctxrow(1, "Project summary and lifecycle", "project.yaml", "0.4k")
                   + ctxrow(2, "Current phase: Build", "phases/build.md + checklist", "1.1k")
                   + ctxrow(3, "Rules for Claude", "agent.md + phases.build.claude", "0.6k")
                   + ctxrow(4, "Task and its spec", "tasks.yaml#LED-42 · specs/transfer-limits.md", "2.3k")
                   + ctxrow(5, "Relevant decisions", "ADR-010, ADR-011", "1.4k")
                   + ctxrow(6, "Map slices", "ledger-service, Create transfer flow, transfers table", "2.4k")
                   + '</ol>'
                   + f'<div style="display: flex; height: 6px; border-radius: 3px; overflow: hidden; gap: 2px">'
                   + "".join(f'<div style="flex: {w}; background: {col}"></div>' for w, col in zip([4, 11, 6, 23, 14, 24], BAR))
                   + '</div>')

    main = f'''<main style="{MAIN_COL}">
{page_header("Project spec", "The .dante folder", "Plain text in the repo, reviewed like code. It defines the lifecycle, what “done” means in each phase and what Claude may propose. Claude reads it before every task.",
             btn("Validate", icon="check") + btn("Export CLAUDE.md", icon="doc"))}
<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min(460px, 100%), 1fr)); gap: 16px; align-items: start">
{editor}
{preview}
</div>
</main>'''
    page("ProjectFormat.dc.html", "Project spec", "ProjectFormat.dc.html", side + main)

# ======================================================================
# Spec in Paper mode (docs-first)
# ======================================================================
def spec_paper():
    P = f"font-family: {SERIF}; font-size: 18px; line-height: 1.65; color: {TX}; margin: 0; text-wrap: pretty"
    H2 = f"font-family: {SERIF}; font-size: 26px; font-weight: 500; letter-spacing: -0.01em; margin: 12px 0 0; color: {TX}"
    def status(t, col):
        return f'<span style="display: inline-flex; align-items: center; gap: 6px; font-family: {SANS}; font-size: 12.5px; color: {col}">{dot(col, 6)}{t}</span>'
    steps = ["Lock account", "Sum outbound today", "Compare with limit", "Write entries + outbox", "Commit"]
    flow_strip = "".join(
        (f'<span style="padding: 8px 12px; border-radius: 8px; border: 1px solid {ACC if i == 1 else LINE2}; background: {ACC_BG if i == 1 else CARD}; font-family: {SANS}; font-size: 13px; color: {TX}; white-space: nowrap">{s}</span>'
         + (f'<span aria-hidden="true" style="color: {TX3}">{ic("chev", 14)}</span>' if i < len(steps) - 1 else "")) for i, s in enumerate(steps))
    figure = (f'<figure style="margin: 8px 0; padding: 18px 20px; border: 1px solid {LINE}; border-radius: 12px; background: {CARD}; display: flex; flex-direction: column; gap: 12px">'
              f'<div style="display: flex; flex-wrap: wrap; align-items: center; gap: 8px">{flow_strip}</div>'
              f'<figcaption style="display: flex; justify-content: space-between; gap: 12px; font-family: {SANS}; font-size: 12px; color: {TX3}; flex-wrap: wrap"><span>Figure 1. The limit is checked inside the account lock (ADR-010).</span><a href="Flow.dc.html">Live from Map › Create transfer</a></figcaption></figure>')

    def acrow(id_, text, st):
        return (f'<tr style="border-top: 1px solid {LINE}"><td style="padding: 10px 14px 10px 0; font-family: {MONO}; font-size: 12px; color: {TX3}; vertical-align: top">{id_}</td>'
                f'<td style="padding: 10px 14px 10px 0; font-family: {SERIF}; font-size: 16.5px; line-height: 1.5">{text}</td><td style="padding: 10px 0; white-space: nowrap; vertical-align: top">{st}</td></tr>')
    table = (f'<div style="overflow-x: auto"><table style="width: 100%; border-collapse: collapse; min-width: 480px"><tbody>'
             + acrow("AC-1", "Transfers under the daily limit go through.", status("Passing", GRN))
             + acrow("AC-2", "A transfer that crosses the limit is rejected with 409.", status("Passing", GRN))
             + acrow("AC-3", "The limit resets at 00:00 UTC.", status("Passing", GRN))
             + acrow("AC-4", "Concurrent transfers cannot exceed the limit together.", status("Failing", RED))
             + acrow("AC-5", "Each rejection writes an audit entry.", status("No tests", AMB))
             + '</tbody></table></div>')

    doc = f'''<article style="max-width: 700px; margin: 0 auto; display: flex; flex-direction: column; gap: 18px">
<div style="display: flex; flex-wrap: wrap; gap: 8px 16px; font-family: {SANS}; font-size: 12.5px; color: {TX3}"><span>specs/transfer-limits.md</span><span>Accepted</span><span>Phase: Build</span><span>Updated Oct 3</span></div>
<h1 style="font-family: {SERIF}; font-size: 46px; line-height: 1.1; font-weight: 500; letter-spacing: -0.02em; margin: 0; color: {TX}">Transfer limits</h1>
<p style="{P}; font-size: 21px; color: {TX2}; font-style: italic">Each account may send at most a set amount per UTC day, so a leaked key or a bug can only move so much money.</p>
<h2 id="rules" style="{H2}">1. Rules</h2>
<p style="{P}">The default limit is 5,000.00 in the account’s currency, stored as 500,000 minor units. An account can carry its own limit in <span style="font-family: {MONO}; font-size: 15px">account_limits</span>, which replaces the default rather than adding to it.</p>
<p style="{P}">The check counts outbound transfers created since 00:00 UTC. It must run after the per-account lock is taken, or two transfers arriving together could both pass.</p>
{figure}
<h2 id="acceptance" style="{H2}">2. Acceptance criteria</h2>
<p style="{P}">Status is live from the last test run.</p>
{table}
<h2 id="open" style="{H2}">3. Open questions</h2>
<p style="{P}">Should incoming transfers raise the limit for the rest of the day? For now they don’t, which is the simpler rule.</p>
</article>'''

    outline = "".join(f'<li><a href="#{a}" style="display: block; padding: 6px 12px; border-radius: 6px; font-size: 13px; color: {TX if i == 0 else TX2}; {"background: " + ACC_BG if i == 0 else ""}">{t}</a></li>'
                      for i, (a, t) in enumerate([("rules", "1. Rules"), ("acceptance", "2. Acceptance criteria"), ("open", "3. Open questions")]))
    left = f'''<aside aria-label="Outline" style="flex: 0 0 220px; box-sizing: border-box; padding: 28px 12px; border-right: 1px solid {LINE}; display: flex; flex-direction: column; gap: 12px">
<div style="padding: 0 12px">{eyebrow("On this page")}</div>
{ul(outline, 2)}
<div style="padding: 12px 12px 0; margin-top: 8px; border-top: 1px solid {LINE}">{eyebrow("Specs")}</div>
{ul("".join(f'<li style="padding: 5px 12px; font-size: 13px; color: {TX2}">{s}</li>' for s in ["Idempotency", "Balance queries", "Receipts", "Reconciliation"]), 0)}
</aside>'''

    def margin_note(icon, title, sub, href):
        return f'<li><a href="{href}" style="display: flex; gap: 10px; padding: 10px 12px; border-radius: 10px; border: 1px solid {LINE}; background: {CARD}; color: {TX}">{ic(icon, 15, TX3)}<span style="display: flex; flex-direction: column; gap: 2px"><span style="font-size: 13px; font-weight: 500">{title}</span><span style="font-size: 12px; color: {TX3}">{sub}</span></span></a></li>'
    right = f'''<aside aria-label="Linked" style="flex: 0 0 260px; box-sizing: border-box; padding: 28px 18px; border-left: 1px solid {LINE}; display: flex; flex-direction: column; gap: 12px">
{eyebrow("Linked to this spec")}
{ul(margin_note("plan", "LED-42", "Enforce daily transfer limits · in progress", "Plan.dc.html")
    + margin_note("code", "limits.ts", "checkDailyLimit · line 9", "Build.dc.html")
    + margin_note("flask", "5 tests", "1 failing: AC-4", "Test.dc.html")
    + margin_note("doc", "ADR-010", "Advisory lock per account", "ProjectFormat.dc.html"), 8)}
</aside>'''

    toolbar = (f'<div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 10px 24px; border-bottom: 1px solid {LINE}">'
               f'<span style="color: {TX3}; font-size: 12.5px">Docs</span>{ic("chev", 12, TX3)}<span style="color: {TX3}; font-size: 12.5px">specs</span>{ic("chev", 12, TX3)}<span style="font-size: 12.5px">transfer-limits.md</span>'
               f'<div style="margin-left: auto; display: flex; gap: 8px; align-items: center">'
               + seg_group("Theme", [ic("moon", 13) + "Dark", ic("sun", 13) + "Light", ic("paper", 13) + "Paper"], ic("paper", 13) + "Paper", "5px 10px")
               + seg_group("Mode", ["Read", "Edit markdown"], "Read", "5px 10px")
               + btn("Export PDF", icon="export") + '</div></div>')
    content = (f'<div style="flex: 999 1 640px; min-width: 0; display: flex; flex-direction: column">{toolbar}'
               f'<div style="flex: 1 1 auto; display: flex; flex-wrap: wrap">{left}<main style="flex: 999 1 560px; min-width: 0; padding: 48px 40px 64px; box-sizing: border-box">{doc}</main>{right}</div></div>')
    page("Spec.paper.dc.html", "Spec in Paper mode", "Spec.paper.dc.html", content, serif=True, h=1240)

# ======================================================================
# Themes sheet
# ======================================================================
def themes():
    cols = []
    for name in ["dark", "light", "paper"]:
        set_theme(name)
        sw = [("Ground", BG), ("Panel", PANEL), ("Card", CARD), ("Line", LINE2), ("Text", TX), ("Text 2", TX2), ("Text 3", TX3), ("Accent", ACC), ("Amber", AMB), ("Green", GRN), ("Red", RED), ("Accent tint", ACC_BG)]
        swatches = "".join(
            f'<li style="display: flex; flex-direction: column; gap: 6px"><span style="height: 44px; border-radius: 8px; background: {c}; border: 1px solid {LINE}"></span>'
            f'<span style="font-size: 11.5px; color: {TX2}">{n}</span><span style="font-family: {MONO}; font-size: 11px; color: {TX3}">{c}</span></li>' for n, c in sw)
        desc = {"dark": "Default. Graphite, low glare, for long sessions of code.",
                "light": "Neutral daylight. Same structure, higher contrast lines.",
                "paper": "Warm ink on paper. Serif reading text for specs and docs; prints and exports this way."}[name]
        strip = "".join(
            (f'<span style="display: flex; align-items: center; gap: 4px; padding: 4px 8px; border-radius: 6px; font-size: 11.5px; color: {TX2}">{ic("check", 11, GRN, 2.5)}{p}</span>' if i < 3 else
             f'<span style="padding: 4px 9px; border-radius: 6px; font-size: 11.5px; font-weight: 600; background: {ACC}; color: {ON_ACC}">{p}</span>' if i == 3 else
             f'<span style="padding: 4px 8px; font-size: 11.5px; color: {TX3}">{p}</span>') for i, p in enumerate(PHASES[:6]))
        reading = (f'<p style="margin: 0; font-family: {SERIF if name == "paper" else SANS}; font-size: {18 if name == "paper" else 14}px; line-height: 1.6; color: {TX}">'
                   'Each account may send at most a set amount per UTC day, so a leaked key can only move so much money.</p>')
        code = (f'<div style="font-family: {MONO}; font-size: 12px; line-height: 20px; background: {CODE_BG}; border: 1px solid {LINE}; border-radius: 8px; padding: 10px 12px">'
                f'<div style="white-space: pre"><span style="color: {K}">export async function</span> <span style="color: {F}">checkDailyLimit</span>(</div>'
                f'<div style="white-space: pre">  amount: <span style="color: {T}">Money</span>, limit = <span style="color: {N}">500_000</span></div>'
                f'<div style="white-space: pre">) {{ <span style="color: {C}">// spec §2</span> <span style="color: {S}">&quot;ok&quot;</span> }}</div></div>')
        col = f'''<section aria-label="{NAME} theme" style="flex: 1 1 380px; min-width: 0; box-sizing: border-box; background: {BG}; color: {TX}; border: 1px solid {LINE}; border-radius: 18px; padding: 28px; display: flex; flex-direction: column; gap: 22px">
<div style="display: flex; flex-direction: column; gap: 6px"><div style="display: flex; align-items: center; gap: 10px">{ic({"dark": "moon", "light": "sun", "paper": "paper"}[name], 18, ACC)}<h2 style="margin: 0; font-size: 22px; font-weight: 600; letter-spacing: -0.01em{"; font-family: " + SERIF + "; font-weight: 500; font-size: 26px" if name == "paper" else ""}">{NAME}</h2></div>
<p style="margin: 0; color: {TX2}">{desc}</p></div>
<ul style="list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px">{swatches}</ul>
<div style="display: flex; flex-wrap: wrap; gap: 2px; padding: 3px; background: {CARD}; border: 1px solid {LINE}; border-radius: 9px; align-self: flex-start">{strip}</div>
<div style="display: flex; flex-wrap: wrap; gap: 8px; align-items: center">{btn("Apply", True)}{btn("Review")}{chip(dot(GRN, 6) + "running")}{chip(dot(AMB, 6) + "restarting")}{mono_chip("ADR-010")}</div>
{reading}
{code}
</section>'''
        cols.append(col)
    set_theme("dark")
    type_rows = [("Display", f"font-family: {SANS}; font-size: 26px; font-weight: 600; letter-spacing: -0.02em", "Geist 600 · 26"),
                 ("UI", f"font-family: {SANS}; font-size: 13px", "Geist 400–600 · 13"),
                 ("Code", f"font-family: {MONO}; font-size: 13px", "Geist Mono · 12.5–13"),
                 ("Reading (Paper)", f"font-family: {SERIF}; font-size: 18px", "Newsreader · 18 / 1.65")]
    types = "".join(f'<li style="display: flex; align-items: baseline; gap: 16px; padding: 10px 0; border-top: 1px solid {LINE}; flex-wrap: wrap"><span style="width: 140px; color: {TX3}; font-size: 12px">{n}</span><span style="flex: 1 1 260px; {s}">The whole lifecycle, in one window</span><span style="font-family: {MONO}; font-size: 11.5px; color: {TX3}">{m}</span></li>' for n, s, m in type_rows)
    html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Dante themes</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
{font_link(True)}
<style>
{base_css()}
</style>
</helmet>
<div style="min-height: 100vh; box-sizing: border-box; padding: 48px 40px 56px; background: {BG}; color: {TX}; display: flex; flex-direction: column; gap: 28px">
<div style="display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: space-between; gap: 16px">
<div style="display: flex; flex-direction: column; gap: 8px">{eyebrow("Design system · v0.1")}<h1 style="margin: 0; font-size: 34px; font-weight: 600; letter-spacing: -0.02em">Three themes, one structure</h1>
<p style="margin: 0; color: {TX2}; max-width: 680px; font-size: 14px">Every screen is built from the same tokens, so switching themes changes colour and reading type, never layout. One accent per theme; amber, green and red are kept for status.</p></div>
<span style="font-family: {MONO}; font-size: 12px; color: {TX3}">⌥⌘T cycles themes</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 20px">{"".join(cols)}</div>
<section style="background: {CARD}; border: 1px solid {LINE}; border-radius: 18px; padding: 24px 28px; display: flex; flex-direction: column; gap: 8px">
<h2 style="margin: 0 0 6px; font-size: 15px; font-weight: 600">Type</h2>{ul(types)}</section>
</div>
</x-dc>
{static_script(1240)}
</body>
</html>
'''
    write("Themes.dc.html", html)

# ======================================================================
# Launch (Main) — unchanged design, re-emitted
# ======================================================================
def launch():
    import shutil
    # Main.dc.html is kept as published; generated by gen.py earlier.
    pass

# ---------- render ----------
set_theme("dark")
overview(); architecture(); flow(); datamodel(); cloud(); build(); palette(); plan(); test(); environments(); release(); operate(); onboarding(); project_format()
themes()
set_theme("light"); overview("Overview.light.dc.html")
set_theme("paper"); spec_paper()
set_theme("dark")

# ---------- canvas index ----------
W = 1440
rows = [
    ("row1", "Launch and daily workspace", [("Main.dc.html", "Launch", 920), ("Onboarding.dc.html", "First open: Claude drafts the spec", 920), ("Overview.dc.html", "Project home", 920), ("Build.dc.html", "Code + Claude", 920), ("Palette.dc.html", "⌘K: search or ask", 920)]),
    ("row2", "Understand: maps generated from the code", [("Architecture.dc.html", "Architecture", 920), ("Flow.dc.html", "Process flow", 920), ("DataModel.dc.html", "Data model", 920), ("Cloud.dc.html", "Cloud (infra project)", 920)]),
    ("row3", "Lifecycle: plan, test, run, ship, operate", [("Plan.dc.html", "Phases and tasks", 920), ("Test.dc.html", "Tests", 920), ("Environments.dc.html", "Docker environments", 920), ("Release.dc.html", "Release", 920), ("Operate.dc.html", "Runtime health", 920)]),
    ("row4", "Themes, docs and the project spec", [("Themes.dc.html", "Themes: Dark, Light, Paper", 1240), ("Overview.light.dc.html", "Project home · Light", 920), ("Spec.paper.dc.html", "Spec · Paper mode", 1240), ("ProjectFormat.dc.html", "Project spec (.dante)", 920)]),
]
# Keep any per-board settings already in the layout (zoom, notes) and replace the positions.
try:
    with open(os.path.join(ROOT, "canvas.json")) as f:
        canvas = json.load(f)
except FileNotFoundError:
    canvas = {"boards": {}}
boards = {}; order = []; notes = {}
y = 0
for key, title, items in rows:
    notes[key] = {"kind": "title1", "maxW": 5 * W + 4 * 80, "text": title, "w": 240, "x": 0, "y": y - 300}
    for c, (fname, t, h) in enumerate(items):
        prev = canvas["boards"].get(fname, {})
        e = dict(prev)
        e.update({"x": c * (W + 80), "y": y, "w": W, "h": h, "title": t, "expand": "fill", "is_interactive": True})
        boards[fname] = e
        order.append(fname)
    y += max(h for _, _, h in items) + 420
canvas["boards"] = boards; canvas["order"] = order; canvas["notes"] = notes
with open(os.path.join(ROOT, "canvas.json"), "w") as f:
    json.dump(canvas, f, indent=2)
print("ok", len(order))
