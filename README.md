# KOReader Knuth–Plass justification plugin

A KOReader plugin that adds a menu for Knuth–Plass paragraph line breaking:
the line-breaking mode, word- and letter-space limits, fit tolerances, line
penalties, emergency stretch and hyphenation penalties.

It needs a CREngine that has Knuth–Plass paragraph formatting (the
`knuth-plass` branch of [spfenwick/crengine](https://github.com/spfenwick/crengine)).
With a stock engine the plugin stays inactive and the menu entry shows
"(unavailable)".

## Install

Copy `knuthplass.koplugin` into KOReader's `plugins/` folder and restart
KOReader. Top menu → Typeset (the document menu) → "Line breaking" opens a
dialog with all the settings in one place. Each setting has a row of
presets, with the current one highlighted, and "…" for a custom value. Tap
a setting's name for an explanation. The dialog can also be assigned to a
gesture ("Knuth–Plass justification settings").

## How settings are stored

- Each value is saved with the book as `copt_<name>` (for example
  `copt_line_breaking_mode`), like KOReader's own bottom-menu settings.
- Long-press a preset, or use "Set as default" in a custom value dialog, to
  make it the default for books without their own value.
- Every setting is a Dispatcher action, so it can be assigned to gestures and
  used in Profiles. Profiles' "from current book settings" includes these
  settings.
- Settings are applied before the document is first rendered. Changing one
  re-renders the book.

## Settings

| Menu entry | Engine properties | Default |
| --- | --- | --- |
| Line breaking | `crengine.style.line.breaking.mode` (0 greedy, 1 Knuth–Plass) | Knuth–Plass |
| Word-space limits | `crengine.style.justify.space.shrink.percent`, `.space.stretch.percent` | −25% / +35% |
| Letter-space limits | `crengine.style.justify.tracking.shrink.percent`, `.tracking.stretch.percent` | −1% / +0% |
| Letter-space smoothness | `crengine.style.justify.tracking.delta.max.bp` | 0.50% |
| Fit tolerance | `crengine.style.justify.pretolerance`, `.tolerance` | 100 / 200 |
| Line-quality penalties | `crengine.style.justify.line.penalty`, `.adjacent.demerits` | 10 / 10000 |
| Emergency & ending | `crengine.style.justify.emergency.stretch.percent`, `.last.line.min.percent` | 6% / 33% |
| Hyphen penalties | `crengine.style.justify.hyphen.penalty`, `.explicit.hyphen.penalty` | 0 / 0 |
| Repeated-hyphen penalties | `crengine.style.justify.double.hyphen.demerits`, `.final.hyphen.demerits` | 0 / 0 |

When no layout of a paragraph fits within the tolerances and the emergency
stretch, the engine makes a last pass that accepts looser lines, so the
paragraph still uses Knuth–Plass. Only a paragraph with a word wider than
the line falls back to greedy breaking. (Engines before this last pass was
added broke such paragraphs greedily, which with large fonts on narrow
screens was about half of them, and then none of these settings applied.)

The hyphen penalties only choose between layouts that fit the word-space
limits; where a line cannot be filled without breaking a word, the hyphen
stays. Measured on a long non-fiction book at 22px on a 600px-wide screen
with the default word-space limits:

| Hyphen penalty | Hyphenated lines |
| --- | --- |
| 0 (free) | 25.9% |
| 1000 (light) | 18.3% |
| 3000 (moderate) | 11.4% |
| 10000 (strong) | 7.6% |

Repeated-hyphen demerits of 1000000 / 3000000 / 10000000 cut consecutive
hyphenated line pairs by about half / two thirds / three quarters. Values
much below these presets have little visible effect.

Ending minimum is a preference, not a rule: its cost grows with the square
of how far the final line falls short, and it only chooses between layouts
that fit the limits above. Same book and screen, paragraphs of two or more
lines:

| Ending minimum | Endings under 33% | Endings of 66% or more |
| --- | --- | --- |
| 0% | 16.9% | 64.7% |
| 33% (default) | 6.6% | 69.0% |
| 50% | 4.7% | 69.0% |
| 66% | 5.1% | 76.8% |
| 80% | 5.0% | 85.2% |

(Engines before this change used a flat cost that was too weak to move most
endings, and above about 33% it made no visible difference.)

## Tests

```sh
./scripts/test.sh
```

The tests run the plugin against stubbed KOReader modules with LuaJIT or
Lua 5.1 (set `LUA=/path/to/interpreter` to choose one).

## License

AGPL-3.0, the same as KOReader.
