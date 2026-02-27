#!/usr/bin/env python3
"""Render each Mermaid diagram from process_flows.html as a high-res PNG image."""

import asyncio
import re
from pathlib import Path
from playwright.async_api import async_playwright

SCRIPT_DIR = Path(__file__).parent
HTML_PATH = SCRIPT_DIR / "process_flows.html"
IMG_DIR = SCRIPT_DIR / "diagram_images"
PROJECT_ROOT = SCRIPT_DIR.parent
MERMAID_JS = PROJECT_ROOT / "node_modules" / "mermaid" / "dist" / "mermaid.min.js"

# Labels for each mermaid block in order of appearance
DIAGRAM_LABELS = [
    "system_overview",
    "data_ingestion",
    "solve_pipeline",
    "presolve_llm",
    "solver_engine",
    "postsolve_llm",
    "auto_runner",
    "contract_lifecycle",
    "decision_ledger",
    "whatif_analysis",
    "end_to_end",
]


def extract_mermaid_blocks(html: str) -> list[str]:
    """Extract all mermaid code blocks from the HTML in order."""
    return re.findall(
        r'<pre\s+class="mermaid">\s*(.*?)\s*</pre>', html, re.DOTALL
    )


def build_single_diagram_html(mermaid_code: str, mermaid_js: str) -> str:
    return f"""<!DOCTYPE html>
<html><head>
<meta charset="UTF-8">
<script>{mermaid_js}</script>
<style>
  body {{ margin: 0; padding: 24px; background: white; }}
  .mermaid {{ display: flex; justify-content: center; }}
</style>
</head><body>
<div class="mermaid">
{mermaid_code}
</div>
<script>
mermaid.initialize({{
  startOnLoad: true,
  theme: 'base',
  themeVariables: {{
    primaryColor: '#ebf5fb',
    primaryBorderColor: '#2e86de',
    primaryTextColor: '#0b1d3a',
    lineColor: '#5a6c7d',
    secondaryColor: '#fef9e7',
    tertiaryColor: '#eafaf1',
    fontSize: '14px'
  }},
  flowchart: {{ htmlLabels: true, curve: 'basis', padding: 16 }}
}});
</script>
</body></html>"""


async def main():
    IMG_DIR.mkdir(exist_ok=True)

    html = HTML_PATH.read_text()
    mermaid_js = MERMAID_JS.read_text()
    blocks = extract_mermaid_blocks(html)
    print(f"Found {len(blocks)} Mermaid diagrams")

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            executable_path="/root/.cache/ms-playwright/chromium-1194/chrome-linux/chrome",
            args=["--no-sandbox", "--disable-setuid-sandbox"],
        )

        for i, code in enumerate(blocks):
            label = DIAGRAM_LABELS[i] if i < len(DIAGRAM_LABELS) else f"diagram_{i+1}"
            page = await browser.new_page(viewport={"width": 1600, "height": 1000})

            diagram_html = build_single_diagram_html(code, mermaid_js)
            tmp = SCRIPT_DIR / f"_tmp_diagram_{i}.html"
            tmp.write_text(diagram_html)

            await page.goto(tmp.resolve().as_uri(), wait_until="domcontentloaded", timeout=15_000)

            await page.wait_for_function(
                """() => {
                    const d = document.querySelector('.mermaid');
                    return d && (d.getAttribute('data-processed') === 'true' || d.querySelector('svg'));
                }""",
                timeout=30_000,
            )
            await asyncio.sleep(0.3)

            mermaid_el = await page.query_selector(".mermaid svg")
            if mermaid_el is None:
                mermaid_el = await page.query_selector(".mermaid")

            out_path = IMG_DIR / f"{i+1:02d}_{label}.png"
            await mermaid_el.screenshot(path=str(out_path))
            print(f"  [{i+1}/{len(blocks)}] {label} -> {out_path.name}")

            await page.close()
            tmp.unlink(missing_ok=True)

        await browser.close()

    print(f"\nAll diagram images saved to {IMG_DIR}/")


if __name__ == "__main__":
    asyncio.run(main())
