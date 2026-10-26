# README brand direction

The repository front door is the product's first impression, so it carries its own brand rather than reading as a reference document.
This page records the three directions that were explored, what each one costs, and where a chosen direction's artwork plugs in.
The final pick belongs to the product owner, so the integration work stays in a later change.

## How the three directions were produced

Each direction is a self-contained HTML prototype of the whole front door: hero, an animated header, a squad diagram, the short operator-voice sections, requirements, quick start, and a brand-kit screen.
The brand-kit screen carries the mark at 16, 24 and 32 pixels on dark and light tiles, horizontal and stacked lockups, a 1280x640 social preview, the mascot in three labelled motion frames, and the palette.
The prototypes were made with `first-draft-axi make` on `gpt-6.1-sol`, then rendered at 1280 and 390 wide in dark and light.
The tool's critic scored them 6, 6 and 7 out of 10 against a plain-prompt baseline, below its own 9-out-of-10 bar, so treat them as directions to choose between rather than as finished pages.
Its recurring findings are worth carrying into the integration: put a real terminal exchange and a finished pull request above the fold, keep the mascot off the phone's first screen where the product evidence should be, and keep one accent hue.
Three small repairs were made by hand to the generated pages: one page painted its light palette on load, one lost a space after a line break at phone width, and one decorative annotation overflowed the mascot at phone width.

## The directions

| Direction | Idea | Palette | Mascot | What it costs |
| --- | --- | --- | --- | --- |
| Deck Arcade | A good night at a well-designed arcade: ink-indigo room, cobalt marquee band, one lime button | ink-indigo, cobalt, acid lime, cream | Bolt, a wind-up crew-bot with a porthole eye and a brass lantern | Loudest and most shareable, and the most toy-like of the three; it reads arcade first, so the terminal exchange has to carry the credibility |
| Dry Dock Blueprint | A shipwright's drawing office: deep slate, amber ink, cyan hairlines, drafting annotations | deep slate, lamp amber, drafting cyan, paper white | Keeper, a line-drawn leviathan carrying a lighthouse | The most premium and precise; quietest on a phone, and it needs discipline to stay warm rather than cold |
| Lantern Tide | A harbour at dusk with lanterns on: warm plum, peach and mint, hand-inked edges | harbour plum, lantern peach, sea-glass mint, paper cream | Luff, a round kraken ferrying two small operators in a sling | Warmest and most memorable, and its mascot already works as loading and empty-state art; gives up some engineering precision, and peach on plum needs contrast care in the light theme |

All three keep one accent hue, a dark canvas as the default theme, and a light theme behind `prefers-color-scheme`, so a `<picture>` pair can be produced from either one.
Copy uses the product's own vocabulary: Juggernaut is the agent distro, the Overwatch is the supervisor, operators do the work, and the reader is the captain.
Requirements and quick start stay accurate: a verified primary harness, git plus an authenticated `gh`, and the chosen backend's dependencies with tmux as the reference default.

## Where a chosen direction wires in

1. The README hero, replacing the current title block, badges and strapline, with a light and dark `<picture>` pair.
2. The repository social preview image, from the 1280x640 composition on the brand-kit screen.
3. The CLI banner and the first-run splash, from the same mark and wordmark lockup.
4. Loading and empty states, which need the mascot as a still pose before any motion exists.
5. The animated working boat in the terminal, which the mascot's motion frames replace.

Assets land as committed SVGs plus raster exports for the social preview and the icon sizes the brand kit already shows, so no step depends on regenerating a prototype.
