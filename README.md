# Rayshader reliefs

A sketchbook of shaded-relief maps rendered in R with [rayshader](https://www.rayshader.com/): modern elevation data, ray-traced light and hand-tuned palettes, several in the style of early-20th-century hypsometric maps.

## Layout

| Folder | Script | What it draws |
| --- | --- | --- |
| `countries/` | `250728_rayshader_norway.R` | Norway, hypsometric relief on a vintage paper basemap |
| | `250728_rayshader_italy.R` | Italy, *carta ipsometrica* (2D experiment) |
| | `260730_rayshader_spain.R` | Spain, *carta hipsométrica* with the 1906 Portugal palette |
| `forgotten-realms/` | `260730_rayshader_forgotten.R` | *Reinos olvidados*: vanished states (e.g. Carthage) drawn on today's relief, borders from a historical atlas |
| `experiments/` | `251013_rayshader_france.R`, `251207_forest_types_poland.R` | Earlier experiments |

`AGENTS.md` describes the house style and the canonical pipeline (`CLAUDE.md` imports it).

**Switzerland and Tolkien's 1911 walk** has its own repository: [thecodeak/tolkien-1911-relief](https://github.com/thecodeak/tolkien-1911-relief).

## Running

R 4.4+ with `pacman`. Run scripts **from the repository root**, e.g. `Rscript countries/260730_rayshader_spain.R`: downloaded data and renders are cached there and shared between scripts. Each script installs its packages and downloads its data on first run. Full-size renders are slow.

## Data

Elevation via [elevatr](https://github.com/USEPA/elevatr) (AWS Terrain Tiles) · borders from [GADM](https://gadm.org/) · rivers from [HydroRIVERS](https://www.hydrosheds.org/products/hydrorivers) · lakes, land and places from [Natural Earth](https://www.naturalearthdata.com/) · historical borders from [aourednik/historical-basemaps](https://github.com/aourednik/historical-basemaps) · ancient places from [Pleiades](https://pleiades.stoa.org/) · lighting HDRIs from [Poly Haven](https://polyhaven.com/). Downloaded data and renders are not committed; each source keeps its own licence.

## Licence

Code: [MIT](LICENSE).
