# Rayshader reliefs

Shaded-relief maps rendered in R with [rayshader](https://www.rayshader.com/): modern elevation data, ray-traced light and hand-tuned palettes, several of them in the style of early-20th-century hypsometric maps.

| Script | What it draws |
| --- | --- |
| `rayshader_elevation_map_swiss.R` | Switzerland with lakes and rivers (base for the Tolkien 1911 route) |
| `250728_rayshader_italy.R`, `250728_rayshader_norway.R` | Hypsometric reliefs of Italy and Norway |
| `250729_rayshader_spain*.R`, `260730_rayshader_spain_v3.R` | Spain, in successive versions |
| `260730_rayshader_forgotten.R` | *Reinos olvidados*: vanished states (e.g. Carthage) drawn on today's relief, borders from a historical atlas |
| `25_rayshader_shivering_isles.R` | A relief built from game heightmaps |
| `france_rayshader.R`, `norway_rayshader*.R`, `forest_types_poland*.R` | Earlier experiments |

`AGENTS.md` / `CLAUDE.md` describe the house style and the canonical pipeline.

## Running

Requires R (4.4+) with `pacman`; each script installs its own packages and downloads its data on first run. Renders at full size are slow.

## Data

Elevation via [elevatr](https://github.com/USEPA/elevatr) (AWS Terrain Tiles) · borders from [GADM](https://gadm.org/) · rivers from [HydroRIVERS](https://www.hydrosheds.org/products/hydrorivers) · lakes, land and places from [Natural Earth](https://www.naturalearthdata.com/) · historical borders from [aourednik/historical-basemaps](https://github.com/aourednik/historical-basemaps) · ancient places from [Pleiades](https://pleiades.stoa.org/) · lighting HDRIs from [Poly Haven](https://polyhaven.com/). Downloaded data and renders are not committed.
