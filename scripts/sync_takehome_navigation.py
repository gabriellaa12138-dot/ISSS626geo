"""Sync the rendered index's Take home menu without re-running analysis.

Render index.qmd after changing _quarto.yml, then run this script from the
project root. It edits only that menu in pages with a Quarto website header.
Revealjs slides and all analysis content are left unchanged.
"""

import argparse
from html import escape
from html.parser import HTMLParser
from pathlib import Path
import posixpath
from urllib.parse import unquote, urlsplit, urlunsplit


class NavigationParser(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.source = source
        self.line_starts = [0]
        for line in source.splitlines(keepends=True):
            self.line_starts.append(self.line_starts[-1] + len(line))
        self.in_header = False
        self.has_header = False
        self.depth = 0
        self.start = None
        self.end = None
        self.links = []
        self.feed(source)

    def source_offset(self):
        line, column = self.getpos()
        return self.line_starts[line - 1] + column

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "header" and values.get("id") == "quarto-header":
            self.in_header = self.has_header = True
        if tag == "ul":
            if self.in_header and values.get("aria-labelledby") == "nav-menu-take-home-exercise":
                if self.start is not None:
                    raise ValueError("More than one Take home menu")
                self.start = self.source_offset()
                self.depth = 1
            elif self.depth:
                self.depth += 1
        if tag == "a" and self.depth:
            self.links.append((self.source_offset(), len(self.get_starttag_text()), attrs))

    def handle_endtag(self, tag):
        if tag == "ul" and self.depth:
            self.depth -= 1
            if not self.depth:
                self.end = self.source.index(">", self.source_offset()) + 1
        if tag == "header":
            self.in_header = False

    def menu(self):
        if self.start is None or self.end is None:
            raise ValueError("Missing or incomplete Take home navigation menu")
        return self.source[self.start:self.end]


def rebase_menu(index, page, site):
    menu = index.menu()
    parent = page.parent.relative_to(site).as_posix()
    for start, length, attrs in reversed(index.links):
        updated = []
        for name, value in attrs:
            if name == "href":
                url = urlsplit(value)
                if not url.scheme and not url.netloc and url.path:
                    target = posixpath.normpath(unquote(url.path))
                    if not (site / target).is_file():
                        raise ValueError(f"Menu target does not exist: {target}")
                    relative = posixpath.relpath(target, parent)
                    if not relative.startswith("."):
                        relative = "./" + relative
                    value = urlunsplit(("", "", relative, url.query, url.fragment))
            updated.append(name if value is None else f'{name}="{escape(value, quote=True)}"')
        replacement = "<a " + " ".join(updated) + ">"
        local_start = start - index.start
        menu = menu[:local_start] + replacement + menu[local_start + length:]
    return menu


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--site", type=Path, default=Path("_site"))
    args.add_argument("--check", action="store_true")
    options = args.parse_args()
    site = options.site
    index = NavigationParser((site / "index.html").read_text(encoding="utf-8"))
    index.menu()
    targets = [dict(attrs).get("href", "") for _, _, attrs in index.links]
    for required in ("take-home_ex03.html", "take-home_ex03_slides.html"):
        if not any(unquote(urlsplit(url).path).endswith(required) for url in targets):
            raise ValueError(f"Render index.qmd first: menu is missing {required}")
    pending = []
    inspected = 0
    for page in sorted(site.rglob("*.html")):
        if any(part == "site_libs" or part.endswith("_files") for part in page.parts):
            continue
        original = page.read_text(encoding="utf-8")
        parsed = NavigationParser(original)
        if not parsed.has_header:
            continue
        inspected += 1
        current = parsed.menu()
        replacement = rebase_menu(index, page, site)
        if replacement != current:
            result = original[:parsed.start] + replacement + original[parsed.end:]
            checked = NavigationParser(result)
            assert result[:checked.start] == original[:parsed.start]
            assert result[checked.end:] == original[parsed.end:]
            pending.append((page, result))
    if options.check:
        print(f"Checked {inspected} website pages; {len(pending)} menus need updating.")
        return bool(pending)
    for page, result in pending:
        page.write_text(result, encoding="utf-8")
        print(f"Updated {page}")
    print(f"Updated {len(pending)} of {inspected} website menus. All other HTML is unchanged.")
    return False


if __name__ == "__main__":
    raise SystemExit(main())
