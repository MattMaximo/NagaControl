# Fable: design the Naga Control logo ("Gamer Boo")

## Matt's ask (his words, condensed)
Design a logo for Naga Control, the little Razer mouse control app: **the classic Boo ghost (normal white body), in a gamer style**, e.g. with a headset and an energy drink can. (Correction from Matt: an earlier "blue ghost" was speech-to-text for "Boo". The ghost stays Boo's standard white with its near-black outline. Don't recolor the body.) Naga Control is becoming a menu-bar item (no Dock icon), so it needs both an app icon and a menu-bar glyph.

## Reference artwork (read-only)
- Boo ghost family repo: `/Users/boostudio/ghosts`. Use `git show origin/main:<path>`; don't edit that repo or its working tree.
  - Locked Boo vector: `src/lib/ghost-avatar/reference/boo.svg` (round crown, mitten side arms, three soft bottom scallops, near-black outline, two big black eyes with white catchlights, tiny smile). The `reference-layers.ts` recipe scales the eyes by 0.85 about each eye's center.
  - Style references: `docs/previews/lumi-family.png`, `exports/profiles/accounting.png` (a ghost holding a prop with its mitten hands), `src/lib/ghost-avatar/reference/accessories/*.svg`.
  - Copies of these are also in `~/.hermes/cache/scratch/ghostref/`.
- House rule for headwear (Matt rejected generic overlays before): draw the headset to fit the ghost's crown silhouette. The band follows the top of the head with a small, controlled gap, and the crown outline stays visible under it. The ear cups sit on the sides of the head. Never just paste a shape over the head curve. The face (eyes, smile) must stay the recognizable Boo face.

## Design
- **Base:** the standard white Boo from `boo.svg`: same silhouette, outline weight, white fill and face. Don't make a new color base.
- **Gamer kit:** a gaming headset with a boom mic, maybe with a subtle Razer-ish green accent (#44D62C) on the ear cups to tie it to the app. One mitten hand holds a generic energy-drink can. **No Red Bull or other real brand marks, logos or names.** Use original can art: a simple lightning bolt or "GG".
- **Expression:** happy, focused, gamer energy. Small variations are OK, but it must still read as Boo.
- **App icon:** a macOS-style rounded-square tile (dark charcoal or a subtle gradient works well with the white ghost and green accent), with the ghost large and centered. It must still read at 32px and 16px.
- **Menu-bar glyph:** a monochrome template image. It's black on transparent and must be legible at 18pt height (18px at @1x, 36px at @2x). It's a simplified silhouette of the gamer ghost: ghost outline + headset band/cup and eyes. Skip the can if it muddies the shape. macOS tints it, so use alpha only.

## Method
Hand-author clean SVG (vector, deterministic). Start from the real `boo.svg` geometry rather than redrawing the ghost. Rasterize with headless Chrome (`"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --screenshot=… --window-size=N,N --default-background-color=00000000`), or with `rsvg-convert` if it's installed. Look at every render yourself (load the PNG with your vision tool) and iterate until it looks polished. Check the small sizes in particular.

## Deliverables: write only inside `/Users/boostudio/NagaControl/Design/`
- `gamer-boo.svg`: the master character (transparent).
- `app-icon.svg` and `AppIcon.icns`, built via an `.iconset` with the standard 16…1024 sizes (`iconutil -c icns`).
- `MenuBarIcon.png` (18×18) and `MenuBarIcon@2x.png` (36×36): black + alpha template.
- `preview.png`: one sheet showing the icon at 1024/128/32/16, the menu-bar glyph on light and dark bars, and the character.
- `README.md`: the design notes, accent hex values, the source references used (commit `git -C ~/ghosts rev-parse origin/main`), and how to re-render.

## Hard gates
- Don't edit `/Users/boostudio/NagaControl/Sources`, `build.sh`, `Resources/` or git history. Another worker is editing the code right now. Boo will wire the icons into the app. Don't commit.
- Don't edit `~/ghosts`, and don't push or deploy anything.
- No real brand trademarks in the art.
- No device I/O, and don't touch the running app.

## Final reply
≤10 plain-English lines: what the logo looks like, where the files are, how you checked the small sizes, and any choice Matt should weigh in on.
