# KOReader Knuth–Plass justification plugin

A KOReader plugin that adds a menu for Knuth–Plass paragraph line breaking:
the line-breaking mode, word- and letter-space limits, fit tolerances, line
penalties, emergency stretch, hyphenation penalties, and the line breaking of
ragged (left-aligned, right-aligned and centered) text.

It needs a CREngine that has Knuth–Plass paragraph formatting (the
`knuth-plass-history` branch of [spfenwick/crengine](https://github.com/spfenwick/crengine)).
With a stock engine the plugin stays inactive, and the menu entry ("install
engine…") offers to install the Knuth–Plass engine where a build is
available (Kobo, KOReader nightly; see [Updates](#updates)).

## Install

Copy `knuthplass.koplugin` into KOReader's `plugins/` folder and restart
KOReader. Top menu → Typeset (the document menu) → "Line breaking" opens a
dialog with all the settings in one place, laid out like KOReader's bottom
menu: one row per setting, its name in a column on the left and its
presets on the right, with the current one highlighted and "…" for a
custom value. Tap
a setting's name for an explanation, and ✕ (or tap outside) to close. The
dialog can also be assigned to a gesture ("Knuth–Plass justification
settings").

## How settings are stored

- Each value is saved with the book as `copt_<name>` (for example
  `copt_line_breaking_mode`), like KOReader's own bottom-menu settings.
- Long-press a preset (or "…" while a custom value is in use), or use "Set
  as default" in a custom value dialog, to make it the default for books
  without their own value. The default is marked ★ (a custom default
  marks "…"). Long-press a setting's name to
  restore its built-in default, or use "Reset all defaults" at the bottom
  of the dialog.
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
| Hyphen penalties | `crengine.style.justify.hyphen.penalty`, `.explicit.hyphen.penalty` | 3000 / 3000 (moderate) |
| Repeated-hyphen penalties | `crengine.style.justify.double.hyphen.demerits`, `.final.hyphen.demerits` | 36000000 / 18000000 (moderate) |
| Ragged text | `crengine.style.ragged.width.percent`, `crengine.style.ragged.hyphen.penalty` | 15% / 100 |

Ragged text only appears with engines that have it (the menu probes
`crengine.style.ragged.width.percent`).

When no layout of a paragraph fits within the tolerances and the emergency
stretch, the engine makes a last pass that accepts looser lines, so the
paragraph still uses Knuth–Plass. Only a paragraph with a word wider than
the line falls back to greedy breaking. (Engines before this last pass was
added broke such paragraphs greedily, which with large fonts on narrow
screens was about half of them, and then none of these settings applied.)

The hyphen penalties only choose between layouts that fit the word-space
limits; where a line cannot be filled without breaking a word, the hyphen
stays. A hyphen penalty counts squared (3000 costs 9000000), while the
repeated-hyphen penalties are added as they are, which is why they are so
much larger. Their presets follow TeX's ratios: a second hyphen in a row
costs 4 times, and a hyphen before the last line twice, a hyphen at the
matching hyphen penalty. (Engines before the cap on them was raised from
10000000 to 1000000000 clamp the larger presets.)

Measured on a long non-fiction book at 22px on a 600px-wide screen with
the default word-space limits (consecutive pairs per 1000 lines):

| Hyphen penalty | Hyphenated lines, repeated free | Pairs, repeated free | Hyphenated lines, repeated moderate | Pairs, repeated moderate |
| --- | --- | --- | --- | --- |
| 0 (free) | 25.3% | 67.4 | 18.5% | 14.8 |
| 1000 (light) | 12.1% | 18.7 | 11.7% | 14.9 |
| 3000 (moderate, default) | 9.1% | 15.5 | 9.0% | 14.8 |
| 10000 (strong) | 8.1% | 15.3 | 8.1% | 14.8 |

Once hyphens have a penalty, repeated-hyphen penalties remove few pairs, and
the strong preset no more than moderate: the rest have no alternative
within the word-space limits. (Looser limits don't help: they let more
lines hyphenate.)

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

Ragged paragraphs keep their natural word spacing (never condensed), and
their line breaks are chosen so that line lengths are as even as possible.
The rag width sets how far short of the full width a line may fall before
it counts as loose (0 leaves these paragraphs to greedy line breaking), and
the ragged hyphen penalty is on a much smaller scale than the justified
ones. Two books forced to left alignment, at 22px on a 600px-wide screen:

| Setting | Hyphenated lines per 1000 | Lines more than 15% short | Pages |
| --- | --- | --- | --- |
| greedy | 154 / 44 | 0.5% / 0% | 3905 / 701 |
| 10% / 100 (even) | 139 / 73 | 0.7% / 2.0% | 4006 / 741 |
| 15% / 100 (balanced, default) | 53 / 42 | 0.6% / 0.6% | 4021 / 741 |
| 15% / 200 (fewer hyphens) | — / 34 | — / 0.6% | — / 742 |
| 20% / 100 | 19 / 18 | 4.8% / 10.8% | 4042 / 742 |

The extra pages come from greedy breaking condensing spaces in ragged text
too.

## Updates

The dialog's "Check for updates" row looks for a newer release of the
plugin on GitHub. "Automatic updates" (tap to change, long-press for help)
sets what happens once a day when KOReader is already online:

- off: nothing
- notify (the default): asks before installing
- install: installs it

An update is unpacked next to the plugin and swapped in only once it is
complete and its checksum matches, and it takes effect after a restart.

Once the plugin is up to date, the check also looks for a Knuth–Plass
engine build for this device and KOReader version, and installs it the same
way (Kobo only, for now):

- The engine only has to agree with the rest of KOReader where they meet:
  `cre.cpp` (the functions KOReader's Lua code calls) and the libraries it
  links. The "Build engine" workflow builds it for the latest nightly and
  lists it in the `engine` release's `manifest.json` under a fingerprint of
  those parts of koreader-base. Nightlies with the same fingerprint share
  the build, so most don't need a new one. A device finds its koreader-base
  from the commit in its KOReader version; if the manifest doesn't list it,
  the newest build is offered.
- Before installing, the plugin loads the new engine in a separate process
  (which fails if a library or function it needs is missing from this
  KOReader) and checks it has every function of the running engine. A build
  that fails isn't offered again for this KOReader version.
- KOReader's own engine is kept as `libs/libkoreader-cre.so.stock`, and the
  dialog's "Restore standard engine" puts it back.
- Until a book has opened with a new engine, KOReader starts in the file
  browser (so the plugin loads before the engine). If the engine fails to
  load, or KOReader stops twice before a book opened with it, the standard
  engine is put back and that build isn't offered again for this KOReader
  version.
- Updating KOReader replaces the engine with its standard one; the next
  check offers the Knuth–Plass engine again.

To publish a release, set `version` in `_meta.lua` and push a matching
tag (`v0.2.0`). The release workflow tests, packages and publishes it.
Engine builds are published by the "Build engine" workflow (on each push to
the crengine branch, daily for new nightlies, or run by hand).

## Tests

```sh
./scripts/test.sh
```

The tests run the plugin against stubbed KOReader modules with LuaJIT or
Lua 5.1 (set `LUA=/path/to/interpreter` to choose one).

## License

AGPL-3.0, the same as KOReader.
