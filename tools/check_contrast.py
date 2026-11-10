#!/usr/bin/env python3
"""
check_contrast.py — WCAG contrast checker for NetLab UZ Stage C.

Reads palettes from ../static/cyber.css (6 themes) and checks
normal-text pairs at 4.5:1 (WCAG AA).

Result categories:
  PASS  — threshold met
  FAIL  — threshold not met (real WCAG violation for the CSS-declared pair)
  SKIP  — cannot be reliably computed from CSS alone
          (translucent bg, missing parent-context info) — neither PASS nor FAIL
  ERROR — technical problem (missing var, invalid color, duplicate theme,
          missing required variable, unclosed CSS comment,
          unresolvable .toast.err rule) — exit code 1

Exit code:
  0 — no FAIL, no ERROR (SKIPs allowed)
  1 — at least one FAIL or ERROR

This is a STATIC analysis of CSS declarations in cyber.css.
It is NOT a full replication of the browser rendering pipeline.
It does not resolve cascade/specificity/@media/computed styles.

Standard library only. No dependencies.

Usage:
  python tools/check_contrast.py
  python check_contrast.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

THEMES = ("cyberpunk", "ocean", "purple", "emerald", "crimson", "light")
THRESHOLD = 4.5

PAIRS = (
    ("text_on_bg",           "--text",       "--bg"),
    ("text_on_panel",        "--text",       "--panel"),
    ("text_on_panel2",       "--text",       "--panel-2"),
    ("muted_on_bg",          "--muted",      "--bg"),
    ("muted_on_panel",       "--muted",      "--panel"),
    ("accent_ink_on_accent", "--accent-ink", "--accent"),
    ("ok_on_ok_bg",          "--ok",         "--ok-bg"),
    ("bad_on_bad_bg",        "--bad",        "--bad-bg"),
    ("text_on_pc",           "--text",       "--pc"),
    ("text_on_sw",           "--text",       "--sw"),
    ("muted_on_pc",          "--muted",      "--pc"),
    ("muted_on_sw",          "--muted",      "--sw"),
)


def _required_theme_vars():
    vars_ = set()
    for _pid, fg, bg in PAIRS:
        if fg.startswith("--"):
            vars_.add(fg)
        vars_.add(bg)
    return frozenset(vars_)


REQUIRED_THEME_VARS = _required_theme_vars()


def strip_css_comments(text):
    """Remove /* ... */ comments. Returns (stripped, error_or_None)."""
    result = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] == '/' and i + 1 < n and text[i + 1] == '*':
            end = text.find('*/', i + 2)
            if end < 0:
                return None, "unclosed CSS comment starting at offset {}".format(i)
            for j in range(i, end + 2):
                result.append('\n' if text[j] == '\n' else ' ')
            i = end + 2
        else:
            result.append(text[i])
            i += 1
    return ''.join(result), None


def parse_theme_blocks(text):
    themes = {}
    errors = []
    for m in re.finditer(r'\[data-theme="([^"]+)"\]\s*\{([^}]*)\}', text):
        theme = m.group(1).strip()
        if theme not in THEMES:
            continue
        if theme in themes:
            errors.append("duplicate theme block for '{}'".format(theme))
            continue
        body = m.group(2)
        vars_in_block = {}
        for decl in body.split(";"):
            decl = decl.strip()
            if not decl.startswith("--") or ":" not in decl:
                continue
            name, val = decl.split(":", 1)
            vars_in_block[name.strip()] = val.strip()
        themes[theme] = vars_in_block
    return themes, errors


def parse_rules(text):
    rules = {}
    for m in re.finditer(r'([^{}]+)\{([^{}]*)\}', text):
        selector = m.group(1).strip()
        if not selector or selector.startswith("@"):
            continue
        if selector.startswith("[data-theme"):
            continue
        body = m.group(2)
        props = {}
        for decl in body.split(";"):
            if ":" not in decl:
                continue
            k, v = decl.split(":", 1)
            k, v = k.strip().lower(), v.strip()
            if k and v:
                props[k] = v
        if props:
            rules[selector] = props
    return rules


HEX_RE = re.compile(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$')
RGB_RE = re.compile(
    r'^(rgb|rgba)\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([0-9]*\.?[0-9]+)\s*)?\)$'
)
VAR_RE = re.compile(r'^var\(\s*(--[\w-]+)\s*\)$')


def parse_color(val):
    if not isinstance(val, str):
        return None
    v = val.strip()
    m = HEX_RE.match(v)
    if m:
        h = m.group(1)
        if len(h) == 3:
            r, g, b = int(h[0] * 2, 16), int(h[1] * 2, 16), int(h[2] * 2, 16)
        else:
            r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
        return ((float(r), float(g), float(b)), 1.0)
    m = RGB_RE.match(v)
    if m:
        kind = m.group(1)
        r, g, b = int(m.group(2)), int(m.group(3)), int(m.group(4))
        a_str = m.group(5)
        if kind == "rgb" and a_str is not None:
            return None
        if kind == "rgba" and a_str is None:
            return None
        a = float(a_str) if a_str is not None else 1.0
        if not (0 <= r <= 255 and 0 <= g <= 255 and 0 <= b <= 255):
            return None
        if not (0.0 <= a <= 1.0):
            return None
        return ((float(r), float(g), float(b)), a)
    return None


def resolve_color(raw, theme_vars):
    if raw is None:
        return None
    m = VAR_RE.match(raw.strip())
    if m:
        return parse_color(theme_vars.get(m.group(1)))
    return parse_color(raw)


def _srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def relative_luminance(rgb):
    r, g, b = rgb
    return (0.2126 * _srgb_to_linear(r)
            + 0.7152 * _srgb_to_linear(g)
            + 0.0722 * _srgb_to_linear(b))


def contrast_ratio(c1, c2):
    L1 = relative_luminance(c1)
    L2 = relative_luminance(c2)
    if L1 < L2:
        L1, L2 = L2, L1
    return (L1 + 0.05) / (L2 + 0.05)


def check_pair(theme_vars, fg_ref, bg_ref):
    fg_raw = fg_ref if fg_ref.startswith("#") else theme_vars.get(fg_ref)
    if fg_raw is None:
        return (None, "ERROR", "missing variable {}".format(fg_ref))
    fg = resolve_color(fg_raw, theme_vars)
    if fg is None:
        return (None, "ERROR", "invalid color {}={}".format(fg_ref, fg_raw))
    bg_raw = theme_vars.get(bg_ref)
    if bg_raw is None:
        return (None, "ERROR", "missing variable {}".format(bg_ref))
    bg = resolve_color(bg_raw, theme_vars)
    if bg is None:
        return (None, "ERROR", "invalid color {}={}".format(bg_ref, bg_raw))
    fg_rgb, fg_a = fg
    bg_rgb, bg_a = bg
    if fg_a < 1.0:
        return (None, "SKIP", "translucent foreground {} (alpha={})".format(fg_ref, fg_a))
    if bg_a < 1.0:
        return (None, "SKIP", "translucent background {} (alpha={}); parent composition not determined from CSS".format(bg_ref, bg_a))
    ratio = contrast_ratio(fg_rgb, bg_rgb)
    return (ratio, "PASS" if ratio >= THRESHOLD else "FAIL", "")


def check_toast_err(theme_vars, rules):
    rule = rules.get(".toast.err")
    if rule is None:
        return (None, "SKIP", "rule .toast.err not found in CSS")
    color_raw = rule.get("color")
    bg_raw = rule.get("background") or rule.get("background-color")
    if color_raw is None:
        return (None, "SKIP", ".toast.err: no 'color' declared")
    if bg_raw is None:
        return (None, "SKIP", ".toast.err: no 'background' declared")
    fg = resolve_color(color_raw, theme_vars)
    if fg is None:
        return (None, "ERROR", ".toast.err color unresolvable: {}".format(color_raw))
    bg = resolve_color(bg_raw, theme_vars)
    if bg is None:
        return (None, "ERROR", ".toast.err background unresolvable: {}".format(bg_raw))
    fg_rgb, fg_a = fg
    bg_rgb, bg_a = bg
    if fg_a < 1.0 or bg_a < 1.0:
        return (None, "SKIP", ".toast.err has translucent color(s)")
    ratio = contrast_ratio(fg_rgb, bg_rgb)
    return (ratio, "PASS" if ratio >= THRESHOLD else "FAIL", "")


def main():
    repo_root = Path(__file__).resolve().parent.parent
    css_path = repo_root / "static" / "cyber.css"
    if not css_path.is_file():
        print("ERROR: {} not found".format(css_path))
        return 1
    raw_text = css_path.read_text(encoding="utf-8")
    text, comment_err = strip_css_comments(raw_text)
    if comment_err is not None:
        print("ERROR: {}".format(comment_err))
        return 1
    themes, parse_errors = parse_theme_blocks(text)
    rules = parse_rules(text)
    if parse_errors:
        for e in parse_errors:
            print("ERROR: {}".format(e))
        return 1
    missing_themes = [t for t in THEMES if t not in themes]
    if missing_themes:
        print("ERROR: themes missing from cyber.css: {}".format(", ".join(missing_themes)))
        return 1
    palette_errors = []
    for theme in THEMES:
        present = set(themes[theme].keys())
        missing_vars = REQUIRED_THEME_VARS - present
        for v in sorted(missing_vars):
            palette_errors.append("theme '{}' is missing required variable {}".format(theme, v))
    if palette_errors:
        for e in palette_errors:
            print("ERROR: {}".format(e))
        return 1
    total = passed = failed = skipped = errored = 0
    failed_pairs = []
    errored_pairs = []
    skipped_pairs = []
    def record(pair_id, ratio, status, note):
        nonlocal total, passed, failed, skipped, errored
        total += 1
        if status == "PASS":
            passed += 1
            print("  {:<26} {:6.2f}:1  PASS".format(pair_id, ratio))
        elif status == "FAIL":
            failed += 1
            failed_pairs.append("{} ({:.2f}:1, needed {})".format(pair_id, ratio, THRESHOLD))
            print("  {:<26} {:6.2f}:1  FAIL (threshold {})".format(pair_id, ratio, THRESHOLD))
        elif status == "SKIP":
            skipped += 1
            skipped_pairs.append("{}: {}".format(pair_id, note))
            print("  {:<26} SKIP   {}".format(pair_id, note))
        else:
            errored += 1
            errored_pairs.append("{}: {}".format(pair_id, note))
            print("  {:<26} ERROR  {}".format(pair_id, note))
    for theme in THEMES:
        tv = themes[theme]
        print("=== {} ===".format(theme))
        for pair_id, fg_ref, bg_ref in PAIRS:
            ratio, status, note = check_pair(tv, fg_ref, bg_ref)
            record(pair_id, ratio, status, note)
        ratio, status, note = check_toast_err(tv, rules)
        record("toast_err", ratio, status, note)
        print()
    print("=== SUMMARY ===")
    print("Total pairs: {}".format(total))
    print("PASS:        {}".format(passed))
    print("FAIL:        {}".format(failed))
    print("SKIP:        {}".format(skipped))
    print("ERROR:       {}".format(errored))
    if skipped_pairs:
        print("\nSkipped (cannot be reliably determined from CSS declarations):")
        for s in skipped_pairs:
            print("  - {}".format(s))
    if failed_pairs:
        print("\nFailed (declared pair below {}:1):".format(THRESHOLD))
        for f in failed_pairs:
            print("  - {}".format(f))
    if errored_pairs:
        print("\nErrored (technical problems):")
        for e in errored_pairs:
            print("  - {}".format(e))
    if failed or errored:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())