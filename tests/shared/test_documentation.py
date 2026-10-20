from pathlib import Path
import re
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[2]


def anchors(path):
    headings = []
    fenced = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("```"):
            fenced = not fenced
        if not fenced and re.match(r"^#{1,6} ", line):
            text = re.sub(r"^#{1,6} ", "", line).lower()
            headings.append(re.sub(r"[^\w\- ]", "", text).replace(" ", "-"))
    return headings


class DocumentationTests(unittest.TestCase):
    def test_readme_stays_a_short_entry_point(self):
        self.assertLessEqual(len((ROOT / "README.md").read_text().splitlines()), 180)

    def test_local_documentation_links_and_heading_anchors_exist(self):
        files = [ROOT / "README.md", *(ROOT / "docs").glob("*.md")]
        for source in files:
            for target in re.findall(r"\]\(([^)]+)\)", source.read_text(encoding="utf-8")):
                parsed = urlsplit(target)
                if parsed.scheme or parsed.netloc:
                    continue
                destination = (source.parent / unquote(parsed.path)).resolve() if parsed.path else source
                with self.subTest(source=source.name, target=target):
                    self.assertTrue(destination.exists(), f"Missing local target: {destination}")
                    if destination.suffix == ".md" and parsed.fragment:
                        self.assertIn(unquote(parsed.fragment), anchors(destination))


if __name__ == "__main__":
    unittest.main()
