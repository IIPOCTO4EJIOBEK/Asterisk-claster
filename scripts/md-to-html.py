#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Собирает читаемый HTML-документ из плана внедрения.

Внешних зависимостей нет намеренно: ни python-markdown, ни pandoc на боевых
машинах может не оказаться, а документ нужно пересобирать после каждой правки
плана. Поддерживается ровно та разметка, которая есть в docs/12-rollout-schedule.md:
заголовки, абзацы, списки, таблицы, цитаты, блоки кода и горизонтальные линии.

    ./scripts/md-to-html.py docs/12-rollout-schedule.md docs/plan/rollout-doc.html
"""

import html
import pathlib
import re
import sys

# ── инлайновая разметка ─────────────────────────────────────────────────────
def inline(text):
    """Экранирует HTML и применяет `код`, **жирный**, *курсив*, [ссылку](url)."""
    out = html.escape(text, quote=False)
    # код первым: внутри него разметка не разбирается
    codes = []
    def stash(m):
        codes.append(m.group(1))
        return f"\x00{len(codes) - 1}\x00"
    out = re.sub(r"`([^`]+)`", stash, out)
    out = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", out)
    out = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<i>\1</i>", out)
    out = re.sub(r"\x00(\d+)\x00", lambda m: f"<code>{codes[int(m.group(1))]}</code>", out)
    return out


def slug(text, seen):
    base = re.sub(r"[^\w\s-]", "", text.lower()).strip()
    base = re.sub(r"[\s-]+", "-", base) or "s"
    n, s = 1, base
    while s in seen:
        n += 1
        s = f"{base}-{n}"
    seen.add(s)
    return s


# ── блочная разметка ────────────────────────────────────────────────────────
def convert(md):
    lines = md.split("\n")
    out, toc, seen = [], [], set()
    i, n = 0, len(lines)

    while i < n:
        ln = lines[i]

        # блок кода
        if ln.startswith("```"):
            lang = ln[3:].strip()
            i += 1
            buf = []
            while i < n and not lines[i].startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            body = html.escape("\n".join(buf), quote=False)
            # комментарии в командах приглушаем
            body = re.sub(r"(?m)(^|\s)(#[^\n]*)$", r"\1<span class=cmt>\2</span>", body)
            cls = f' class="lang-{lang}"' if lang else ""
            out.append(f"<pre><code{cls}>{body}</code></pre>")
            continue

        # заголовки
        m = re.match(r"^(#{1,4})\s+(.*)$", ln)
        if m:
            lvl, txt = len(m.group(1)), m.group(2).strip()
            sid = slug(txt, seen)
            out.append(f'<h{lvl} id="{sid}">{inline(txt)}</h{lvl}>')
            if lvl <= 2:
                toc.append((lvl, sid, txt))
            i += 1
            continue

        # горизонтальная линия
        if re.match(r"^---+\s*$", ln):
            out.append("<hr>")
            i += 1
            continue

        # таблица
        if ln.startswith("|") and i + 1 < n and re.match(r"^\|[\s:|-]+\|\s*$", lines[i + 1]):
            head = [c.strip() for c in ln.strip("|").split("|")]
            aligns = []
            for c in lines[i + 1].strip("|").split("|"):
                c = c.strip()
                aligns.append("right" if c.endswith(":") and not c.startswith(":")
                              else "center" if c.startswith(":") and c.endswith(":")
                              else "left")
            i += 2
            rows = []
            while i < n and lines[i].startswith("|"):
                rows.append([c.strip() for c in lines[i].strip("|").split("|")])
                i += 1
            th = "".join(
                f'<th style="text-align:{aligns[j] if j < len(aligns) else "left"}">{inline(c)}</th>'
                for j, c in enumerate(head))
            trs = []
            for r in rows:
                tds = "".join(
                    f'<td style="text-align:{aligns[j] if j < len(aligns) else "left"}">{inline(c)}</td>'
                    for j, c in enumerate(r))
                trs.append(f"<tr>{tds}</tr>")
            out.append('<div class="tbl"><table><thead><tr>' + th + "</tr></thead><tbody>"
                       + "".join(trs) + "</tbody></table></div>")
            continue

        # цитата
        if ln.startswith(">"):
            buf = []
            while i < n and lines[i].startswith(">"):
                buf.append(lines[i].lstrip(">").strip())
                i += 1
            out.append("<blockquote>" + inline(" ".join(buf).strip()) + "</blockquote>")
            continue

        # списки
        if re.match(r"^[-*]\s+", ln) or re.match(r"^\d+\.\s+", ln):
            ordered = bool(re.match(r"^\d+\.\s+", ln))
            pat = r"^\d+\.\s+" if ordered else r"^[-*]\s+"
            items = []
            while i < n and (re.match(pat, lines[i]) or
                             (lines[i].startswith("  ") and lines[i].strip() and items)):
                if re.match(pat, lines[i]):
                    items.append(re.sub(pat, "", lines[i]).strip())
                else:
                    items[-1] += " " + lines[i].strip()
                i += 1
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>" + "".join(f"<li>{inline(x)}</li>" for x in items) + f"</{tag}>")
            continue

        # пустая строка
        if not ln.strip():
            i += 1
            continue

        # абзац
        buf = []
        while i < n and lines[i].strip() and not re.match(
                r"^(#{1,4}\s|```|\||>|---+\s*$|[-*]\s|\d+\.\s)", lines[i]):
            buf.append(lines[i].strip())
            i += 1
        out.append("<p>" + inline(" ".join(buf)) + "</p>")

    return "\n".join(out), toc


def render_toc(toc):
    if not toc:
        return ""
    parts = ['<nav class="toc" aria-label="Содержание"><div class="toc-h">Содержание</div><ol>']
    for lvl, sid, txt in toc:
        parts.append(f'<li class="l{lvl}"><a href="#{sid}">{html.escape(txt)}</a></li>')
    parts.append("</ol></nav>")
    return "".join(parts)


STYLE = """
:root{
  --bg:#F4F6F8; --surface:#FFFFFF; --surface-2:#EDF1F4;
  --ink:#161C24; --ink-2:#3D4956; --muted:#6B7885;
  --line:#D8DEE5; --line-soft:#E7ECF1;
  --accent:#125C6B; --accent-soft:#E2EFF1;
  --warn:#8E6118; --crit:#9B3F37;
  --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
  --serif:Georgia,"Iowan Old Style","Times New Roman",serif;
  --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --bg:#0F1419; --surface:#161D25; --surface-2:#1D262F;
  --ink:#E6ECF2; --ink-2:#B7C2CE; --muted:#8695A3;
  --line:#2A353F; --line-soft:#222C35;
  --accent:#5FB3C4; --accent-soft:#14313A;
  --warn:#D9A85A; --crit:#E08A80;
}}
:root[data-theme="dark"]{
  --bg:#0F1419; --surface:#161D25; --surface-2:#1D262F;
  --ink:#E6ECF2; --ink-2:#B7C2CE; --muted:#8695A3;
  --line:#2A353F; --line-soft:#222C35;
  --accent:#5FB3C4; --accent-soft:#14313A;
  --warn:#D9A85A; --crit:#E08A80;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:var(--serif);font-size:17px;line-height:1.68;-webkit-font-smoothing:antialiased}
.page{max-width:1180px;margin:0 auto;padding:0 24px 96px;
  display:grid;grid-template-columns:minmax(0,1fr) 250px;gap:48px;align-items:start}
main{max-width:74ch;min-width:0}
h1,h2,h3,h4,.toc,table,figcaption{font-family:var(--sans)}
h1{font-size:2.15rem;line-height:1.12;letter-spacing:-.02em;font-weight:650;
  margin:0 0 .5em;text-wrap:balance;padding-top:56px}
main>h1:not(:first-of-type){margin-top:1.4em;padding-top:36px;border-top:2px solid var(--line)}
h2{font-size:1.32rem;letter-spacing:-.01em;font-weight:620;margin:2em 0 .5em;text-wrap:balance}
h3{font-size:1.04rem;font-weight:620;margin:1.7em 0 .4em}
h4{font-size:.95rem;font-weight:620;margin:1.4em 0 .3em;color:var(--ink-2)}
p{margin:0 0 1.05em}
ul,ol{margin:0 0 1.05em;padding-left:1.3em}
li{margin-bottom:.4em}
a{color:var(--accent)}
b{font-weight:640}
code{font-family:var(--mono);font-size:.86em;background:var(--surface-2);
  padding:.1em .36em;border-radius:3px;word-break:break-word}
pre{background:var(--surface);border:1px solid var(--line);border-radius:8px;
  padding:15px 17px;overflow-x:auto;margin:0 0 1.2em;font-size:.82rem;line-height:1.6}
pre code{background:none;padding:0;font-size:inherit}
.cmt{color:var(--muted)}
blockquote{margin:0 0 1.2em;padding:14px 18px;background:var(--surface);
  border-left:3px solid var(--warn);border-radius:0 8px 8px 0;font-size:.97rem}
blockquote p:last-child{margin-bottom:0}
hr{border:0;border-top:1px solid var(--line-soft);margin:2.4em 0}
.tbl{overflow-x:auto;border:1px solid var(--line);border-radius:8px;
  background:var(--surface);margin:0 0 1.4em}
table{border-collapse:collapse;width:100%;font-size:.88rem}
th,td{padding:9px 13px;border-bottom:1px solid var(--line-soft);vertical-align:top}
th{font-size:.72rem;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);
  font-weight:600;background:var(--surface-2);white-space:nowrap}
tr:last-child td{border-bottom:0}
.toc{position:sticky;top:24px;font-size:.82rem;line-height:1.45;
  max-height:calc(100vh - 48px);overflow-y:auto;padding-top:60px}
.toc-h{font-size:.7rem;text-transform:uppercase;letter-spacing:.11em;
  color:var(--muted);font-weight:600;margin-bottom:10px}
.toc ol{list-style:none;margin:0;padding:0;border-left:1px solid var(--line)}
.toc li{margin:0}
.toc a{display:block;padding:4px 12px;text-decoration:none;color:var(--ink-2);
  border-left:2px solid transparent;margin-left:-1px}
.toc a:hover{color:var(--accent);border-left-color:var(--accent)}
.toc .l1>a{font-weight:640;color:var(--ink);margin-top:10px}
.toc .l2>a{padding-left:22px}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
@media (max-width:960px){
  .page{grid-template-columns:1fr;gap:0}
  .toc{position:static;max-height:none;padding-top:24px;margin-bottom:24px;
    border-bottom:1px solid var(--line);padding-bottom:16px}
  h1{padding-top:32px}
}
@media (max-width:680px){body{font-size:16px}h1{font-size:1.7rem}}
@page{ size:A4; margin:16mm 14mm; }
@media print{
  body{background:#fff;color:#000;font-size:10.5pt}
  .page{display:block;max-width:none;padding:0}
  .toc{display:none}
  h1{padding-top:0;page-break-before:always}
  main>h1:first-of-type{page-break-before:avoid}
  h1,h2,h3{page-break-after:avoid}
  pre,blockquote,.tbl,table{page-break-inside:avoid}
  a{color:#000;text-decoration:none}
}
"""


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip())
        return 2
    src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    md = src.read_text(encoding="utf-8")
    body, toc = convert(md)
    m = re.search(r"^#\s+(.*)$", md, re.M)
    title = m.group(1).strip() if m else src.stem
    doc = (f"<!doctype html>\n<html lang=\"ru\">\n<head>\n<meta charset=\"utf-8\">\n"
           f"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
           f"<title>{html.escape(title)}</title>\n<style>{STYLE}</style>\n</head>\n<body>\n"
           f'<div class="page">\n<main>\n{body}\n</main>\n{render_toc(toc)}\n</div>\n'
           f"</body>\n</html>\n")
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(doc, encoding="utf-8")
    print(f"записан: {dst} | {len(doc)} символов, разделов в содержании: {len(toc)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
