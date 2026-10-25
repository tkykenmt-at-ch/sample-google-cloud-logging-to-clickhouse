"""MkDocs hook: adapt the GitHub-flavored Markdown of the repository to the docs site.

- The home page of each language is README.md / README.ja.md, with its links rewritten for the site.
- The "English | 日本語" line at the top of each page is dropped; the site has its own language switcher.
- GitHub alerts (> [!NOTE]) become admonitions.
- In Japanese pages, the line break between two sentences is dropped (it would render as a space).
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPO = "https://github.com/tkykenmt-at-ch/sample-google-cloud-logging-to-clickhouse"
READMES = {"en/index.md": "README.md", "ja/index.md": "README.ja.md"}

# English | [日本語](../ja/setup.md), [English](../en/setup.md) | 日本語, and the README forms with "·".
LANG_LINE = re.compile(r"^(English [|·] \[日本語\]\([^)]*\)|\[English\]\([^)]*\) [|·] 日本語)\n+", re.M)
ALERT = re.compile(r"^> \[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\n((?:>.*\n?)+)", re.M)
ALERT_KIND = {"NOTE": "note", "TIP": "tip", "IMPORTANT": "info", "WARNING": "warning", "CAUTION": "danger"}
LINK = re.compile(r"\]\(([^)\s]+)\)")
IMG_TAG = re.compile(r'<img src="([^"]+)" alt="([^"]*)" width="(\d+)">')


def _alert(m):
    body = re.sub(r"^> ?", "    ", m.group(2), flags=re.M)
    return f"!!! {ALERT_KIND[m.group(1)]}\n\n{body}"


def _readme_target(lang, target):
    if re.match(r"[a-z]+:|#", target):
        return target
    if target.startswith(f"docs/{lang}/"):
        return target[len(f"docs/{lang}/"):]
    if target.startswith("docs/images/"):
        return "../" + target[len("docs/"):]
    if target in ("README.md", "README.ja.md"):
        return {"README.md": "../en/index.md", "README.ja.md": "../ja/index.md"}[target]
    # Anything else (LICENSE, terraform/, sql/...) is not on the site: link to it on GitHub.
    kind = "tree" if target.endswith("/") else "blob"
    return f"{REPO}/{kind}/main/{target}"


def _readme(lang, name):
    text = (ROOT / name).read_text(encoding="utf-8")
    text = LINK.sub(lambda m: f"]({_readme_target(lang, m.group(1))})", text)
    # MkDocs rewrites Markdown image paths per page but not raw <img> paths: make them Markdown images.
    text = IMG_TAG.sub(lambda m: f'![{m.group(2)}]({_readme_target(lang, m.group(1))}){{ width="{m.group(3)}" }}', text)
    # Let Markdown inside the HTML blocks render (md_in_html).
    text = text.replace('<div align="center">', '<div align="center" markdown>')
    text = text.replace("<details>", "<details markdown>")
    return text


def on_page_markdown(markdown, page, config, files, **kwargs):
    src = page.file.src_uri
    if src in READMES:
        markdown = _readme(src.split("/")[0], READMES[src])
    markdown = LANG_LINE.sub("", markdown, count=1)
    return ALERT.sub(_alert, markdown)


PRE = re.compile(r"(<pre.*?</pre>)", re.S)
# One sentence per source line: a line break after a Japanese sentence renders as a space. Drop it.
JA_BREAK = re.compile(r"(?<=[。！？）」])\n(?=\S)")


def on_page_content(html, page, config, files, **kwargs):
    if not page.file.src_uri.startswith("ja/"):
        return html
    parts = PRE.split(html)
    return "".join(p if i % 2 else JA_BREAK.sub("", p) for i, p in enumerate(parts))
