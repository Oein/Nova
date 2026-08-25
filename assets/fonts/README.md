# Bundled font

Nova ships its own font rather than asking the OS for one. Two reasons:

* **Identical rendering everywhere.** The TypeScript build asked CSS for
  `ui-monospace, SFMono-Regular, Consolas, …` and got a different face, with
  different advance widths, on every platform — which is why it had to *measure*
  a rendered `"M"` at runtime and re-measure after `document.fonts.ready`.
  Owning the font means the cell metrics are known up front.
* **Golden-image tests are only meaningful with a fixed font.**

| File | Coverage | License |
| --- | --- | --- |
| `D2Coding-Regular.ttf` | Hangul, CJK, Latin | SIL OFL 1.1 (`OFL-D2Coding.txt`) |

## Why one font, and why this one

The editor lays text out on a fixed cell grid: a wide (East Asian) glyph must be
*exactly* two narrow cells, or the caret and the selection rectangles drift away
from the painted glyphs on any line that mixes scripts. D2Coding is drawn to
that ratio — Latin at 0.5 em, Hangul at 1.0 em — because it is a Korean coding
font.

Pairing a Latin coding font with a separate CJK font does not hold the ratio.
JetBrains Mono's Latin cell is 0.6 em, so its cells and D2Coding's Hangul cells
disagree by 20%. That is precisely the class of bug the TypeScript build fought,
and it is not worth reintroducing for a prettier `a`.

Bold is synthesized by emboldening the outline, which keeps the download 4 MB
smaller than shipping a second weight for the handful of bold headings a note
contains.

## User-chosen fonts

A font picked in **Settings** goes to the head of the fallback chain, and the
bundled face stays behind it, so a font missing Hangul still shows Korean text.
Fallback faces are rescaled so their cells land on the chosen font's grid
(`FontStack.matchFallbackSizes`) — the scripts may differ slightly in visual
weight, which is the right trade against a grid that does not hold.
