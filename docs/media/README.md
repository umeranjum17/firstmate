# README media

`logo-light.svg` and `logo-dark.svg` are themed wordmark marks from first-draft-axi (authorized stand-ins; self-score below the design bar).

`social-preview.png` is the 1280×640 GitHub social card candidate from first-draft-axi (authorized stand-in; labeled below the 9 bar in the PR). Upload under repository Settings → General → Social preview.

`hero-light.webp`, `hero-dark.webp`, `hero-phone-light.webp`, and `hero-phone-dark.webp` are real Lookout Overview captures of a live fleet through lookout-adapter (not Sample fleet).

Reproduce the captures with:

```sh
LOOKOUT_URL=http://<host>:4390 done-done run readme-hero
# or: FM_HOME=<Firstmate home> LOOKOUT_DIR=<lookout clone> done-done run readme-hero
```

Encode PNGs to WebP with `magick in.png -quality 80 out.webp` into this directory when refreshing the README hero.
