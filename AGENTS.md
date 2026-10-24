# AGENTS.md — Vintage Hypsometric Relief Maps (rayshader / R)

## What this project is

A collection of R scripts that reproduce the look of the **1906 "Carta Hypsometrica"**
vintage relief maps — the reference is `Portugal_Topo_relief_processed_4000.jpg`
(*Commissão do Serviço Geologico, Carta Hypsometrica de Portugal*). Each script takes
one country, builds a high-resolution DEM, drapes a warm hypsometric colour ramp over
the shaded relief, floods the surroundings with pale "paper", and renders it as a raised
3D relief lit by a studio HDRI — then furnishes it in `magick` with vintage typography,
a legend swatch, and neighbour/sea labels.

**The `Portugal_Topo_relief_processed_4000.jpg` image is the canonical style + palette
target.** When in doubt about colour, shadow softness, sea tone, river colour, or
typography, match that image.

## The house style (what "good" looks like)

- **3D raised relief** floating on cream paper, with a **soft ray-traced drop shadow**.
- **Hypsometric palette:** green/khaki lowlands → straw → tan → orange → deep brown peaks.
  High luminance — the terrain must stay *bright and warm*, never muddy/grey.
- **Sea:** pale celadon (`#C9E0D8` shelf → `#AFCFC9` deep), flat, at paper level.
- **Neighbouring land:** near-white warm paper (`#F4F1E7`), flattened (no relief).
- **Hydrography:** teal rivers (width scaled by `ORD_FLOW`), celadon lakes, engraved
  coastline/border ink line (`#5E5140`).
- **Cities:** small dots + labels for capitals and major towns (see Portugal reference).
- **Typography:** `Playfair Display`, dark sepia ink (`#4A3B28` / `#3E3120`), wide kerning.
  Title stack: `COMISIÓN / CARTA HIPSOMÉTRICA / DE / <PAÍS> / 1906`.

## Canonical pipeline (follow this order)

1. **Setup** — `pacman::p_load(terra, elevatr, sf, geodata, tidyverse, rayshader, magick)`,
   `sf::sf_use_s2(FALSE)`, download HDRI once.
2. **Geometry** — GADM level-0 for the country; drop far-flung parts (Canaries, Svalbard,
   overseas). Pick a **country-appropriate projected CRS** (see table). Build a `frame`
   = country bbox + margin; fetch neighbours clipped to the frame for the "paper".
3. **DEM** — `elevatr::get_elev_raster()` over the *frame*, reproject to CRS, crop,
   then **force square pixels** via `terra::resample` to `mean(res)`.
4. **Downsample** — bring the matrix long side to `TARGET_MAX` with **`terra::aggregate(fun="mean")`**
   (NOT `resize_matrix` — it moirés). Re-binarise masks after any interpolation.
5. **Mask & flatten** — rasterize country + neighbours; set outside-country to 0 and
   clamp `< 0` to 0 (kill land bathymetry).
6. **Texture** — `height_shade(m, texture = hypso)`, then paint the flat zone:
   sea where `is.na(mask)`, paper where `is.na(mask) & !is.na(neigh)`.
7. **Shading** — `ray_shade` + `ambient_shade` (+ optional `lamb_shade`). **Keep it light**
   (`max_darken` ≈ 0.3–0.5, `sunaltitude` ≈ 40–45) or the palette greys out.
8. **Overlays** — lakes (polygon) → rivers (lines) → cities (points + labels) → border line.
9. **Render** — `plot_3d(..., solid=FALSE, shadow=FALSE, phi=89, theta=0)` then
   `render_highquality(light=FALSE, environment_light=hdri, samples=256..350)`.
10. **Furnish** — `magick`: title, neighbour/sea labels, legend swatch, optional paper grain.

## Per-country conventions

| Country | ISO | CRS | Drop | Notes |
|---|---|---|---|---|
| Norway | `NOR` | `EPSG:25833` (UTM33N) | Svalbard, Jan Mayen, Bear I. | 3D, good |
| Italy | `ITA` | `EPSG:32633` (UTM33N) | micro-islets < 50 km² | **2D — superseded, do not copy** |
| Spain | `ESP` | `EPSG:25830` (UTM30N) | **Canary Islands** (keep mainland + Balearics) | 3D @ 2000px + cities |

Switzerland (Swiss oblique Mercator, the original 3D baseline) lives in
[thecodeak/tolkien-1911-relief](https://github.com/thecodeak/tolkien-1911-relief).

## Rendering budget (hard-won)

- **3D at ≤ 2000 px is tractable; 4000×4000 is not** on a typical workstation.
- Keep the **shading matrix ~1000–1500 long side**; render the *image* at ~2000.
  Detail comes from `samples`, not from an enormous matrix.
- **Do NOT resurrect the Italy 2D path** (`plot_map` + `box_blur` fake shadow +
  `image_modulate(saturation=92)`): it produced jagged shadows, greyed the palette, and
  showed vertical tile-seam striping. Use the 3D path.

## Gotchas / lessons learned

- **Vertical striping** = elevatr tile seams magnified over a too-large frame. Mitigate:
  modest margins, `terra::aggregate(fun="mean")`, moderate zoom (`z=7` for Spain-sized).
- **Grey/muddy terrain** = too much stacked `add_shadow` and/or `image_modulate` desaturation.
  Fewer shadow passes, higher `sunaltitude`, no saturation cut.
- **`resize_matrix` moiré** → use `terra::aggregate`.
- Masks interpolate to fractional values when resized → re-threshold to `NA`/`1`.
- `sf::sf_use_s2(FALSE)` before any clipping, or `st_intersection` throws.
- Fonts: `Playfair Display` must be installed; check with `magick::magick_fonts()`.

## Data assets already on disk (do not re-download)

- `gadm/gadm41_*_0_pk.rds` — cached GADM L0 (ALB, AUT, CHE, FIN, FRA, HRV, ITA, NOR, RUS,
  SMR, SVN, SWE, TUN, VAT). **Spain/Portugal/Andorra not yet cached** → will fetch on first run.
- `HydroRIVERS_v10_eu_shp/` — HydroSHEDS European rivers (`ORD_FLOW` = stream order).
- `ne_lakes/ne_10m_lakes.shp` — Natural Earth 10m lakes.
- `photo_studio_loft_hall_4k.hdr` — studio HDRI for `render_highquality`.

## Data source URLs

- HDRI: `https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/photo_studio_loft_hall_4k.hdr`
- Rivers: `https://data.hydrosheds.org/file/HydroRIVERS/HydroRIVERS_v10_eu_shp.zip`
- Lakes: `https://naciscdn.org/naturalearth/10m/physical/ne_10m_lakes.zip`
- **Cities:** `https://naciscdn.org/naturalearth/10m/cultural/ne_10m_populated_places.zip`
  (filter `ADM0NAME == "Spain"`, rank by `POP_MAX` / `SCALERANK`, flag `FEATURECLA` for capital)

## Palette reference (the Portugal ramp)

**Corrected 2026-07-30 by sampling the reference plate's own legend swatch
(`Portugal_Topo_relief_processed_4000.jpg`, which is actually a WebP — decode with PIL,
the swatch sits at ~(755, 3220)-(780, 3375) in the 3000×4000 original).**
The Portugal ramp has **no green in it at all** — it is a *desert* ramp running from
near-cream flats to umber peaks. The greenish cast on the reference is the celadon
**sea**, not the land. Earlier scripts had green lowlands; that was wrong.

```r
hypso_stops <- c("#F5F1E6","#F0E7D3","#E9DCBC","#E0CDA2","#D6BA85",  # cream → sand
                 "#CBA463","#BE8B40","#AC7124","#925612","#75400A")  # ochre → orange → umber
pos <- c(0,.05,.11,.19,.29,.42,.57,.73,.88,1)^0.90
sea_shelf <- "#CFE2DA"; sea_deep <- "#AFCFC9"; paper <- "#F4F1E7"
river <- "#4E8B80"; lake <- "#77A9A0"; ink <- "#5E5140"; ink_soft <- "#9C907C"
```

Consequence: because the low ground is now nearly the same value as the paper, a
**cream-lowland country must get an engraved outline** (`ink`, linewidth ≈ 2.4) or its
coast dissolves into the background. Spain v2 does this.

## File naming

`YYMMDD_rayshader_<country>.R`, filed by kind:

- `countries/` — modern country plates (Norway, Italy, Spain)
- `experiments/` — early one-offs outside the house style (France, Poland forests)

Run every script **from the repo root** (`Rscript countries/260730_rayshader_spain.R`):
data caches (`gadm/`, `ne_*/`, `HydroRIVERS_*/`, the HDRI) and renders
live there and are shared between scripts. `private/` is gitignored and never pushed.

Outputs: `<country>_carta.png` (raw render) →
`<country>_carta_final.png` (furnished). Keep intermediate `.rds`/shp caches in place.

## Sister repositories

- `thecodeak/tolkien-1911-relief` — Switzerland and Tolkien's 1911 walk.
- `thecodeak/forgotten-realms-relief` — vanished states on modern relief. Its `AGENTS.md`
  copies the palette and rendering notes from this file; **this file is the source of
  truth for the house style**, so carry palette changes over to it.
