# Naga Control logo: "Gamer Boo"

The standard white Boo ghost wearing a gaming headset with a boom mic and holding an
unbranded energy can. Open `preview.png` to see everything on one sheet.

Nothing in this folder is wired into the app yet. `Sources/`, `Resources/` and
`build.sh` were not touched.

## Files

| File | What it is |
|---|---|
| `gamer-boo.svg` | Master character, transparent background. |
| `app-icon.svg` | App icon artwork, 1024 canvas. Used for 128 px and larger. |
| `app-icon-64.svg`, `app-icon-32.svg`, `app-icon-16.svg` | Simplified drawings for the three small icon sizes. |
| `AppIcon.iconset/`, `AppIcon.icns` | The ten standard macOS sizes (16 to 1024) and the packed icon. |
| `menu-bar-glyph.svg` → `MenuBarIcon@2x.png` (36×36) | Menu-bar template glyph, Retina. |
| `menu-bar-glyph-1x.svg` → `MenuBarIcon.png` (18×18) | Menu-bar template glyph, @1x. |
| `preview.png` | Review sheet: icon sizes, glyph on light and dark bars, the character. |
| `build_logo.py` | Rebuilds every file above. |

## Design notes

**The ghost is Boo, unchanged.** The body, outline, eyes, eye highlights and smile are
read verbatim from the locked Boo vector at build time; the script never redraws them.
The body stays white with Boo's own near-black outline. The eyes use the approved
recipe from `reference-layers.ts`: scaled 0.85 about each eye's centre. Boo's light-grey
ground shadow is left out, because it is a separate layer in the recipe and looks wrong
on a dark tile.

**The headset is fitted to the crown.** The band is a true offset of Boo's own crown
contour: an even gap above the head, with the crown outline fully visible under it. The
band runs down behind the ear cups, which sit on the sides of the head and follow the
head's tilt. Each cup is a dark cushion on the face side and a green shell outside.

**Boom mic.** It comes out from behind the left cushion, curves under the left eye and
ends in a capsule below-left of the smile. It touches neither the eye nor the smile.

**Energy can.** Original art only: a plain green can with a silver lid and tab and a
black lightning bolt. No brand names or marks. Boo's right mitten is pulled across the
can's left side so it reads as held; the arm outline underneath is still Boo's own.

**App icon.** macOS grid (824 px tile on a 1024 canvas, continuous corners), charcoal
gradient, faint green glow behind the head. Boo's outline is near-black, so on the dark
tile the mascot gets a thin light sticker rim; without it the headband and can outline
sink into the tile. On dark backgrounds use the rimmed `app-icon.svg` artwork rather
than the bare `gamer-boo.svg`.

**Small icon sizes (64, 32, 16 px).** The full mascot turns into a white blob with green
flecks at these sizes: the outline breaks up and the mic and can become noise. They use
a simplified front-facing Boo instead: white ghost, two eyes, smile (64 and 32 only),
light band with a gap above the head, green cups. The 16 px one is set pixel by pixel.

**Menu-bar glyph.** Template image: pure black plus alpha, macOS tints it. A solid
upright ghost with the eyes knocked out, three hem scallops, a band with a clear gap
above the head and two ear cups. No can and no mic; they muddy the shape at 18 pt. The
36 px file is anti-aliased vector; the 18 px file is drawn pixel by pixel with no grey
pixels. Load the pair as one image and set `isTemplate = true`.

## Colours

| Use | Hex |
|---|---|
| Accent green (ear cups, can, mic light) | `#44D62C` |
| Accent shade / highlight | `#2A9E18` / `#A5F291` |
| Boo outline (from `boo.svg`) | `#060505` |
| Boo body | `#FFFFFF` |
| Headband and boom | `#474C56`, highlight `#7C8492` |
| Ear cushions, mic capsule | `#2B2E34` |
| Can lid and base | `#D5D9DF`, shade `#9AA1AC` |
| Icon tile gradient, top → bottom | `#33373F` → `#121316` |
| Sticker rim on the tile | `#F3F5F8` |
| Headband in the 16/32/64 px icons | `#BCC3CF` |

## Source references

Read-only from `~/ghosts` at `origin/main` =
`f17df54370314e1e962a2e4b498ecfe80eb39171` (pinned in `build_logo.py` as `GHOSTS_COMMIT`):

- `src/lib/ghost-avatar/reference/boo.svg`: the locked Boo vector (geometry source).
- `src/lib/ghost-avatar/reference/reference-layers.ts`: eye-scale recipe and eye centres.
- `src/lib/ghost-avatar/reference/accessories/backward-cap.svg`, `lumi-bow.svg`: how
  family accessories are drawn and fitted.
- `docs/previews/lumi-family.png`, `exports/profiles/accounting.png`: family style and
  how a ghost holds a prop in its mitten.

## Re-render

```sh
python3 Design/build_logo.py             # everything: SVGs, PNGs, .iconset, .icns, preview
python3 Design/build_logo.py --svg-only  # SVGs only (no Chrome needed)
```

Needs Python 3 (standard library only), Google Chrome in `/Applications` for
rasterising, the system `iconutil`, and the `~/ghosts` checkout with the pinned commit
available. To follow a newer Boo vector, change
`GHOSTS_COMMIT` and rebuild; the kit is positioned from Boo's contour, so check
`preview.png` afterwards.

Tuning knobs are constants near the top of each section of the script: `Kit` (band gap,
band thickness, cup size), `MIC_AT`, `CAN_CENTER` / `CAN_TILT` / `CAN_SCALE`,
`GRIP_REACH`, `RIM_WIDTH`, and the `ICON_16` / `GLYPH_1X` pixel grids.

## How it was checked

- Every render was reviewed by eye at full size and as zoomed crops (headband gap, cup
  joins, mic path, can and mitten).
- 16, 32 and 64 px icons and both menu-bar files were reviewed as nearest-neighbour
  enlargements (one block per real pixel) and at real size on light, dark and coloured
  backdrops.
- Menu-bar PNGs verified numerically: 18×18 and 36×36, every visible pixel pure black,
  the 18 px file has no partly transparent pixels.
- `AppIcon.icns` unpacks back to all ten sizes with `iconutil -c iconset`.
