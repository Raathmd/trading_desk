#!/usr/bin/env python3
"""Generate a PDF of the Trading Desk Process Flows page.

Uses Playwright (headless Chromium) to render the HTML with Mermaid diagrams,
then prints to PDF with print-friendly styling.

The CDN Mermaid script is replaced with a local copy so it works offline.
"""

import asyncio
import re
from pathlib import Path
from playwright.async_api import async_playwright

SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
HTML_PATH = SCRIPT_DIR / "process_flows.html"
PDF_PATH = SCRIPT_DIR / "process_flows.pdf"
MERMAID_JS = PROJECT_ROOT / "node_modules" / "mermaid" / "dist" / "mermaid.min.js"


def build_offline_html() -> Path:
    """Replace the CDN mermaid <script> with an inline local copy."""
    html = HTML_PATH.read_text()
    mermaid_code = MERMAID_JS.read_text()

    # Find and replace CDN script tag with inline script
    match = re.search(
        r'<script\s+src="https://cdn\.jsdelivr\.net/npm/mermaid@[^"]*"></script>',
        html,
    )
    if match:
        html = html[: match.start()] + f"<script>{mermaid_code}</script>" + html[match.end() :]

    tmp = SCRIPT_DIR / "_process_flows_offline.html"
    tmp.write_text(html)
    return tmp


async def main():
    tmp_html = build_offline_html()
    html_url = tmp_html.resolve().as_uri()
    print(f"Loading offline HTML: {tmp_html.name}")

    try:
        async with async_playwright() as p:
            chromium_path = "/root/.cache/ms-playwright/chromium-1194/chrome-linux/chrome"
            browser = await p.chromium.launch(
                headless=True,
                executable_path=chromium_path,
                args=["--no-sandbox", "--disable-setuid-sandbox"],
            )
            page = await browser.new_page()

            # Load; domcontentloaded is enough since mermaid is now inline
            await page.goto(html_url, wait_until="domcontentloaded", timeout=30_000)

            # Wait for all mermaid diagrams to render
            await page.wait_for_function(
                """() => {
                    const diagrams = document.querySelectorAll('.mermaid');
                    return diagrams.length > 0 &&
                           Array.from(diagrams).every(d =>
                               d.getAttribute('data-processed') === 'true' ||
                               d.querySelector('svg') !== null
                           );
                }""",
                timeout=60_000,
            )
            print(f"All Mermaid diagrams rendered.")

            # Inject print-optimized CSS
            await page.add_style_tag(content="""
                .nav { display: none !important; }
                .header { padding: 30px 40px 24px !important; }
                .section {
                    break-inside: avoid;
                    page-break-inside: avoid;
                    margin-bottom: 24px !important;
                }
                .diagram {
                    break-inside: avoid;
                    page-break-inside: avoid;
                }
                body { background: white !important; -webkit-print-color-adjust: exact; }
                .content { padding: 20px 24px 40px !important; }
            """)

            await asyncio.sleep(0.5)

            await page.pdf(
                path=str(PDF_PATH.resolve()),
                format="A4",
                print_background=True,
                margin={
                    "top": "16mm",
                    "bottom": "16mm",
                    "left": "12mm",
                    "right": "12mm",
                },
            )

            await browser.close()

        print(f"PDF saved to {PDF_PATH.resolve()}")
    finally:
        # Clean up temp file
        tmp_html.unlink(missing_ok=True)


if __name__ == "__main__":
    asyncio.run(main())
