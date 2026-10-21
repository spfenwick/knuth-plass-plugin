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
KOReader. The settings are under top menu → Typeset (the document menu) →
"Line breaking".

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

When no line breaking for a paragraph fits within the tolerances and the
emergency stretch, that paragraph is broken greedily. This happens more
often with large fonts on narrow screens; raising "Emergency" stretch (for
example to 10%) or "Max +" word spacing lets more paragraphs use Knuth–Plass.

## Tests

```sh
./scripts/test.sh
```

The tests run the plugin against stubbed KOReader modules with LuaJIT or
Lua 5.1 (set `LUA=/path/to/interpreter` to choose one).

## License

AGPL-3.0, the same as KOReader.
