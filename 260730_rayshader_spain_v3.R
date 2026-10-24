# ============================================================
# CARTA HIPSOMETRICA DE ESPAÑA  —  v2 (Swiss-style clean relief)
#
# Feedback-driven redesign:
#   * The RENDER is JUST a clean floating relief + shadow (like the Swiss
#     map): country clipped to NA outside → floats, real contact shadow,
#     Portugal hypsometric palette, water + city dots draped on top.
#   * ALL the vintage "carta" chrome (title, legend, neighbour/sea names,
#     border, grain) is POST-PROCESSING in magick — a separate block that
#     reads the rendered PNG back from disk, so you can retune typography
#     WITHOUT re-rendering (the expensive step).
#
# Run PART 1+2 once to render; then re-run PART 3 as often as you like.
# ============================================================

# ============================================================
# PART 1 — DATA
# ============================================================
if (!require("pacman")) install.packages("pacman")
pacman::p_load(terra, elevatr, sf, geodata, tidyverse, rayshader, magick)

sf::sf_use_s2(FALSE)

# ---- PARAMETERS (tune here) --------------------------------
ISO        <- "ESP"
CRS_PROJ   <- "EPSG:25830"          # ETRS89 / UTM30N — correct shape for Iberia
Z_LEVEL    <- 7                     # elevatr zoom (7 ~ plenty for a 2000px map)
TARGET_MAX <- 1400                  # shading-matrix long side
ZSCALE     <- 12                    # LOWER = more vertical drama. Try 8–18.
MARGIN     <- c(-60000, -60000, 60000, 60000)   # small: relief floats, no paper needed
RENDER_MAX <- 2000                  # long side of the rendered PNG
N_CITIES   <- 16
SHOW_CITY_DOTS   <- TRUE
SHOW_CITY_LABELS <- TRUE            # baked into the relief (correctly georeferenced)

RELIEF_PNG <- "spain_relief.png"    # PART 2 writes this; PART 3 reads it
FINAL_PNG  <- "spain_carta_final_v2.png"

# HDRI studio light (already on disk; downloads once if missing)
u <- "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/photo_studio_loft_hall_4k.hdr"
hdri_file <- basename(u)
if (!file.exists(hdri_file)) download.file(u, hdri_file, mode = "wb")

# ---- geometry: peninsular Spain + Balearics, drop Canaries -----
cty <- geodata::gadm(ISO, level = 0, path = getwd()) |> st_as_sf() |> st_make_valid()
parts <- st_cast(cty, "POLYGON") |> st_make_valid()
cent  <- st_coordinates(st_centroid(parts))
parts <- parts[cent[, 2] > 34 & cent[, 1] > -10, ]
parts <- parts[as.numeric(st_area(parts)) > 3e7, ]
cty   <- st_union(parts) |> st_as_sf() |> st_make_valid()
cty_p <- st_transform(cty, CRS_PROJ)

frame_bbox <- st_bbox(cty_p) + MARGIN
frame_sf   <- st_as_sfc(frame_bbox) |> st_set_crs(CRS_PROJ)
frame_ll   <- st_transform(frame_sf, 4326)

# ---- DEM, square pixels ------------------------------------
dem_raw <- elevatr::get_elev_raster(st_as_sf(frame_ll), z = Z_LEVEL) |>
  terra::rast() |> terra::project(CRS_PROJ) |> terra::crop(terra::vect(frame_sf))
res_t <- mean(terra::res(dem_raw))
dem <- terra::resample(dem_raw, terra::rast(extent = terra::ext(dem_raw),
                                            crs = CRS_PROJ, resolution = res_t))

# ---- CLIP to country → NA outside so the relief FLOATS (Swiss trick) ----
mask_r <- terra::rasterize(terra::vect(cty_p), dem)
dem_relief <- dem
dem_relief[is.na(mask_r)]  <- NA     # <- NA, not 0: outside is not drawn
dem_relief[dem_relief < 0] <- 0      # clamp any sub-sea land to 0

long_side  <- max(dim(dem)[1:2])
agg_factor <- max(1, round(long_side / TARGET_MAX))
dem_relief_s <- terra::aggregate(dem_relief, fact = agg_factor, fun = "mean", na.rm = TRUE)

m <- rayshader::raster_to_matrix(dem_relief_s)
cat("shading matrix:", dim(m), "  (agg_factor =", agg_factor, ")\n")

# ---- hydrography + cities ----------------------------------
if (!file.exists("ne_lakes/ne_10m_lakes.shp")) {
  lu <- "https://naciscdn.org/naturalearth/10m/physical/ne_10m_lakes.zip"
  download.file(lu, basename(lu), mode = "wb"); unzip(basename(lu), exdir = "ne_lakes")
}
lakes <- st_read("ne_lakes/ne_10m_lakes.shp", quiet = TRUE) |> st_make_valid() |>
  st_transform(CRS_PROJ) |> st_intersection(cty_p)

if (!file.exists("HydroRIVERS_v10_eu_shp/HydroRIVERS_v10_eu.shp")) {
  ru <- "https://data.hydrosheds.org/file/HydroRIVERS/HydroRIVERS_v10_eu_shp.zip"
  download.file(ru, basename(ru), mode = "wb"); unzip(basename(ru))
}
rivers <- st_read(list.files("HydroRIVERS_v10_eu_shp", "\\.shp$", full.names = TRUE),
                  wkt_filter = st_as_text(st_as_sfc(st_bbox(frame_ll))), quiet = TRUE) |>
  st_intersection(cty) |> st_transform(CRS_PROJ) |>
  mutate(w = as.numeric(ORD_FLOW),
         width = case_when(w <= 3 ~ 4.5, w == 4 ~ 3.2, w == 5 ~ 2.2,
                           w == 6 ~ 1.5, w == 7 ~ 1.0, w == 8 ~ 0.55, TRUE ~ 0)) |>
  filter(width > 0)

if (!file.exists("ne_cities/ne_10m_populated_places.shp")) {
  cu <- "https://naciscdn.org/naturalearth/10m/cultural/ne_10m_populated_places.zip"
  download.file(cu, basename(cu), mode = "wb"); unzip(basename(cu), exdir = "ne_cities")
}
cities <- st_read("ne_cities/ne_10m_populated_places.shp", quiet = TRUE) |>
  filter(ADM0NAME == "Spain") |>
  st_transform(CRS_PROJ) |> st_intersection(cty_p) |>
  mutate(is_cap = str_detect(FEATURECLA, "capital"), label = NAME) |>
  arrange(desc(is_cap), desc(POP_MAX)) |> slice_head(n = N_CITIES)

# ============================================================
# PART 2 — CLEAN RELIEF RENDER (the hero; slow step)
# ============================================================

# Portugal hypsometric ramp, sampled off the 1906 plate's own legend swatch:
# it is a DESERT ramp — cream flats → sand → ochre → burnt orange → umber peaks.
# (No green at all: the greenish cast on the reference is the celadon sea, not land.)
hypso_stops <- c("#F5F1E6", "#F0E7D3", "#E9DCBC", "#E0CDA2", "#D6BA85",
                 "#CBA463", "#BE8B40", "#AC7124", "#925612", "#75400A")
pos   <- c(0, .05, .11, .19, .29, .42, .57, .73, .88, 1)^0.90
hypso <- grDevices::colorRamp(hypso_stops)(pos) |> rgb(maxColorValue = 255) |>
         colorRampPalette()
hypso <- hypso(512)

tex <- rayshader::height_shade(m, texture = hypso)

# shading — light touch keeps the palette bright and warm
ray <- rayshader::ray_shade(m, zscale = ZSCALE, sunaltitude = 42,
                            sunangle = 315, multicore = TRUE)
amb <- rayshader::ambient_shade(m, zscale = ZSCALE, maxsearch = 20, multicore = TRUE)

ext_s <- dem_relief_s
final_map <- tex |>
  add_shadow(ray, max_darken = 0.40) |>
  add_shadow(amb, max_darken = 0.22) |>
  add_overlay(generate_polygon_overlay(lakes, extent = ext_s, heightmap = m,
                                        palette = "#77A9A0", linewidth = 0),
              alphalayer = 0.9) |>
  add_overlay(generate_line_overlay(rivers, extent = ext_s, heightmap = m,
                                    color = "#4E8B80", linewidth = rivers$width,
                                    data_column_width = "width"),
              alphalayer = 0.85)

# the desert ramp starts at near-cream, so the coast no longer separates itself
# from the paper on its own — engrave the outline back in (house style, #5E5140)
final_map <- final_map |>
  add_overlay(generate_line_overlay(
    sf::st_cast(sf::st_boundary(cty_p), "MULTILINESTRING"),
    extent = ext_s, heightmap = m, color = "#5E5140", linewidth = 2.4),
    alphalayer = 0.85)

if (SHOW_CITY_DOTS) {
  final_map <- final_map |>
    add_overlay(generate_point_overlay(cities, extent = ext_s, heightmap = m,
                                       color = "#3E3120", size = 3, pch = 19),
                alphalayer = 0.95)
}
if (SHOW_CITY_LABELS) {
  final_map <- tryCatch(
    final_map |>
      add_overlay(rayshader::generate_label_overlay(
        cities, extent = ext_s, heightmap = m, text_size = 1.4, point_size = 0,
        color = "#3E3120", halo_color = "#F4F1E7", halo_expand = 3,
        font = 2, data_label_column = "label", seed = 1), alphalayer = 1),
    error = function(e) { message("no label overlay: ", conditionMessage(e)); final_map })
}

rayshader::plot_map(final_map)   # quick 2D sanity peek

# aspect-correct render size
asp <- as.numeric(diff(frame_bbox[c(1, 3)]) / diff(frame_bbox[c(2, 4)]))
if (asp >= 1) { rw <- RENDER_MAX; rh <- round(RENDER_MAX / asp)
} else        { rh <- RENDER_MAX; rw <- round(RENDER_MAX * asp) }

# Floating relief + real contact shadow onto the paper groundplane (Swiss recipe)
rayshader::plot_3d(
  final_map, m,
  zscale = ZSCALE,
  solid = FALSE,
  shadow = TRUE, shadow_darkness = 0.9,
  background = "#F4EFE3",
  windowsize = c(round(rw / 2), round(rh / 2)),
  zoom = 0.72, phi = 89, theta = 0
)

rayshader::render_highquality(
  filename = RELIEF_PNG,
  preview  = FALSE,
  light    = FALSE,
  environment_light = hdri_file,
  intensity_env = 1.15,
  interactive = FALSE,
  width = rw, height = rh,
  samples = 256                 # sobol_blue cap (your working setting)
)

# ============================================================
# PART 3 — POST-PROCESSING (cheap; re-run freely to retune)
# Reads RELIEF_PNG from disk, so it runs standalone after a render.
# ============================================================
stopifnot(file.exists(RELIEF_PNG))
# fonts fallback? -> print(magick::magick_fonts(), n = 200)
raw <- image_read(RELIEF_PNG)
W <- image_info(raw)$width; H <- image_info(raw)$height

# rebuild the ramp here too, so PART 3 works even if run on its own
hypso_stops <- c("#F5F1E6","#F0E7D3","#E9DCBC","#E0CDA2","#D6BA85",
                 "#CBA463","#BE8B40","#AC7124","#925612","#75400A")
hypso <- colorRampPalette(hypso_stops)(512)

x <- function(f) round(W * f); y <- function(f) round(H * f)

plate <- raw |>
  image_annotate("COMISIÓN DEL SERVICIO GEOLÓGICO", font = "Playfair Display",
                 size = y(0.020), gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.06)),
                 color = "#4A3B28", kerning = 6) |>
  image_annotate("CARTA HIPSOMÉTRICA", font = "Playfair Display",
                 size = y(0.036), gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.095)),
                 color = "#4A3B28", kerning = 10) |>
  image_annotate("D E", font = "Playfair Display", size = y(0.018), gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.145)), color = "#6B5B45") |>
  image_annotate("ESPAÑA", font = "Playfair Display", weight = 700, size = y(0.075),
                 gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.165)), color = "#3E3120") |>
  image_annotate("(según la carta corográfica a escala 1:500 000)", size = y(0.015),
                 gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.255)), color = "#6B5B45") |>
  image_annotate("1906", font = "Playfair Display", size = y(0.022), gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.285)), color = "#4A3B28") |>
  # neighbour + sea letterpress (nudge locations to taste)
  image_annotate("P O R T U G A L", size = y(0.024), degrees = 90, kerning = 12,
                 gravity = "west", location = paste0("+", x(0.02), "+", y(0.06)),
                 color = "#B9B2A2") |>
  image_annotate("F R A N C I A", size = y(0.024), kerning = 12, gravity = "north",
                 location = paste0("+", x(0.18), "+", y(0.02)), color = "#B9B2A2") |>
  image_annotate("M A R   M E D I T E R R Á N E O", size = y(0.020), kerning = 8,
                 gravity = "southeast", location = paste0("+", x(0.05), "+", y(0.10)),
                 color = "#9AB7B0") |>
  image_annotate("O C É A N O   A T L Á N T I C O", size = y(0.020), degrees = 90,
                 kerning = 8, gravity = "west",
                 location = paste0("+", x(0.02), "+", y(0.30)), color = "#9AB7B0")

# legend swatch
sw <- image_graph(180, 300, res = 96); par(mar = c(0, 0, 0, 0))
image(1, seq_len(12), t(matrix(1:12)),
      col = rev(hypso[seq(1, 512, length.out = 12)]),
      axes = FALSE, xlab = "", ylab = ""); box(col = "#6B5B45"); dev.off()
plate <- image_composite(plate, sw, offset = paste0("+", x(0.06), "+", H - 380)) |>
  image_annotate("LEYENDA", font = "Playfair Display", size = y(0.018),
                 gravity = "southwest", location = paste0("+", x(0.06), "+", 400),
                 color = "#4A3B28", kerning = 6)

final <- image_border(plate, "#EDEAE2", "90x90")
image_write(final, FINAL_PNG, quality = 97)

cat("\nRelief  →", RELIEF_PNG, "\nFinished →", FINAL_PNG, " (", W, "x", H, ")\n")
cat("Retune chrome by re-running PART 3 alone — no re-render needed.\n")