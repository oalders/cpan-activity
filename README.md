# cpan-activity

Reproduce the CPAN activity numbers and charts from
[Recent CPAN Activity](https://www.olafalders.com/2026/09/02/recent-cpan-activity/).

Everything talks to the public [MetaCPAN API](https://api.metacpan.org/) using
only **core Perl** — `HTTP::Tiny` and `JSON::PP` both ship with Perl, so there is
nothing to install. A stock `perl` can verify every figure in the post.
(Fittingly, you don't need CPAN to measure CPAN.)

## Usage

```bash
perl cpan-activity.pl            # print the report
perl cpan-activity.pl --charts   # also (re)write the four SVG charts
```

`--charts` writes `uploads.svg.html`, `releasers.svg.html`, `firsttime.svg.html`
and `newdist.svg.html` into the current directory — theme-aware inline SVG
grouped bar charts, cyan for 2025 and orange for 2026.

## What it measures

A year-over-year read on the window **1 January → 31 August** (end of day),
applied identically to both years so a partial 2026 is compared like-for-like
against the same slice of 2025. All metrics are derived from MetaCPAN's
`release` index:

| Metric | Definition |
| --- | --- |
| uploads | every release, including re-releases of a distribution |
| releasers | distinct PAUSE authors who uploaded anything |
| first-time releasers | authors whose first-*ever* CPAN upload lands in the window |
| new distributions | releases flagged `first => true` by MetaCPAN |

Numbers move as CPAN moves underneath you — new uploads keep arriving, and
deletions can lower a count — so a re-run may differ slightly from the figures
in the post.

## License

MIT
