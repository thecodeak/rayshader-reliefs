# ============================================================
# CARTA HIPSOMETRICA DE ESPAÑA
# Vintage hypsometric relief in the style of the 1906 Portugal map.
#
# Strategy (see CLAUDE.md): go back to the *3D* pipeline that made
# Switzerland / Norway / Portugal sing (raised relief + soft ray-traced
# drop shadow + studio HDRI) but keep it at the tractable ~2000 px size.
# This is the opposite of the Italy experiment, which went 2D and greyed
# out / striped. Adds cities, rivers and lakes on top.
# ============================================================

# 1. SETUP ---------------------------------------------------
if (!require("pacman")) install.packages("pacman")
pacman::p_load(terra, elevatr, sf, geodata, tidyverse, rayshader, magick, png)

sf::sf_use_s2(FALSE)

# ---- PARAMETERS (tune here) --------------------------------
ISO        <- "ESP"
NEIGH      <- c("PRT", "FRA", "AND", "MAR")   # paper-coloured surroundings
CRS_PROJ   <- "EPSG:25830"          # ETRS89 / UTM30N — correct shape for Iberia
Z_LEVEL    <- 7                     # elevatr zoom (7 ~ plenty for a 2000px map)
TARGET_MAX <- 1400                  # shading-matrix long side (detail = samples, not size)
ZSCALE     <- 15                    # LOWER = more vertical drama. Try 8–20.
MARGIN     <- c(-100000, -100000, 100000, 100000)   # frame padding, metres
RENDER_MAX <- 2000                  # long side of the final PNG (2000 = tractable)
N_CITIES   <- 18                    # how many towns to label

# HDRI studio light (already on disk; downloads once if missing)
u <- "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/photo_studio_loft_hall_4k.hdr"
hdri_file <- basename(u)
if (!file.exists(hdri_file)) download.file(u, hdri_file, mode = "wb")

# 2. GEOMETRY ------------------------------------------------
cty <- geodata::gadm(ISO, level = 0, path = getwd()) |> st_as_sf() |> st_make_valid()

# Keep peninsular Spain + Balearics; DROP the Canary Islands (they sit far
# south-west and would wreck the frame). Split to polygons, cull by centroid.
parts <- st_cast(cty, "POLYGON") |> st_make_valid()
cent  <- st_coordinates(st_centroid(parts))
parts <- parts[cent[, 2] > 34 & cent[, 1] > -10, ]              # lat > 34N, lon > 10W
parts <- parts[as.numeric(st_area(parts)) > 3e7, ]             # drop micro-islets < 30 km²
cty   <- st_union(parts) |> st_as_sf() |> st_make_valid()
cty_p <- st_transform(cty, CRS_PROJ)

# Frame = country bbox + margin (the "paper")
frame_bbox <- st_bbox(cty_p) + MARGIN
frame_sf   <- st_as_sfc(frame_bbox) |> st_set_crs(CRS_PROJ)
frame_ll   <- st_transform(frame_sf, 4326)

# Neighbouring land for the paper texture (clipped to the frame)
neigh <- lapply(NEIGH, \(x) tryCatch(
           geodata::gadm(x, 0, path = getwd()) |> st_as_sf(), error = \(e) NULL)) |>
  compact() |> bind_rows() |> st_make_valid() |>
  st_transform(CRS_PROJ) |> st_intersection(frame_sf) |> st_make_valid()

# 3. DEM OVER THE WHOLE FRAME --------------------------------
dem_raw <- elevatr::get_elev_raster(st_as_sf(frame_ll), z = Z_LEVEL) |>
  terra::rast() |> terra::project(CRS_PROJ) |> terra::crop(terra::vect(frame_sf))

# force square pixels (prevents the classic horizontal "squish")
res_t <- mean(terra::res(dem_raw))
dem <- terra::resample(dem_raw, terra::rast(extent = terra::ext(dem_raw),
                                            crs = CRS_PROJ, resolution = res_t))

# 4. DOWNSAMPLE via area-averaging (NOT resize_matrix → moiré) ----
long_side  <- max(dim(dem)[1:2])
agg_factor <- max(1, round(long_side / TARGET_MAX))

mask_r  <- terra::rasterize(terra::vect(cty_p), dem)   # 1 inside Spain
neigh_r <- terra::rasterize(terra::vect(neigh), dem)   # 1 on neighbour land

dem_relief <- dem
dem_relief[is.na(mask_r)]  <- 0      # flatten everything outside Spain
dem_relief[dem_relief < 0] <- 0      # kill land bathymetry

bath <- dem; bath[bath >= 0] <- NA   # sea depth only

dem_relief_s <- terra::aggregate(dem_relief, fact = agg_factor, fun = "mean")
mask_s       <- terra::aggregate(mask_r,     fact = agg_factor, fun = "modal")
neigh_s      <- terra::aggregate(neigh_r,    fact = agg_factor, fun = "modal")
bath_s       <- terra::aggregate(bath,       fact = agg_factor, fun = "mean")

m       <- rayshader::raster_to_matrix(dem_relief_s)
m_mask  <- rayshader::raster_to_matrix(mask_s)
m_neigh <- rayshader::raster_to_matrix(neigh_s)
m_bath  <- rayshader::raster_to_matrix(bath_s)

cat("shading matrix:", dim(m), "  (agg_factor =", agg_factor, ")\n")
stopifnot(identical(dim(m), dim(m_mask)))

# 5. HYPSOMETRIC TEXTURE (the Portugal ramp) -----------------
# green/khaki lowlands → straw → tan → orange → deep-brown peaks.
hypso_stops <- c("#8FA977", "#AEBB88", "#CFC79B", "#E2CE9B",
                 "#D9A566", "#C6813F", "#A05E29", "#7A431B")
# non-linear stops: give the lowlands room, compress the rare high peaks
pos   <- c(0, .05, .12, .22, .36, .55, .78, 1)^0.85
hypso <- grDevices::colorRamp(hypso_stops)(pos) |> rgb(maxColorValue = 255) |>
         colorRampPalette()
hypso <- hypso(512)

tex <- rayshader::height_shade(m, texture = hypso)

# ---- paint the flat zone: sea + neighbour paper ------------
sea_shal <- col2rgb("#C9E0D8") / 255     # shelf celadon
sea_deep <- col2rgb("#AFCFC9") / 255     # deep celadon
paper    <- col2rgb("#F4F1E7") / 255     # neighbour land (warm near-white)

depth <- pmin(1, abs(pmin(m_bath, 0, na.rm = TRUE)) / 2500)
depth[is.na(depth)] <- 0
outside <- is.na(m_mask)

for (i in 1:3) {
  ch <- tex[, , i]
  ch[outside] <- (sea_shal[i] * (1 - depth) + sea_deep[i] * depth)[outside]
  ch[outside & !is.na(m_neigh)] <- paper[i]          # neighbours = paper, not sea
  tex[, , i] <- ch
}

# 6. SHADING (light touch — keep the palette bright) ---------
ray <- rayshader::ray_shade(m, zscale = ZSCALE, sunaltitude = 42,
                            sunangle = 315, multicore = TRUE)
amb <- rayshader::ambient_shade(m, zscale = ZSCALE, maxsearch = 20, multicore = TRUE)

# 7. VECTOR OVERLAYS -----------------------------------------
# A. Lakes (Natural Earth 10m)
if (!file.exists("ne_lakes/ne_10m_lakes.shp")) {
  lu <- "https://naciscdn.org/naturalearth/10m/physical/ne_10m_lakes.zip"
  download.file(lu, basename(lu), mode = "wb"); unzip(basename(lu), exdir = "ne_lakes")
}
lakes <- st_read("ne_lakes/ne_10m_lakes.shp", quiet = TRUE) |> st_make_valid() |>
  st_transform(CRS_PROJ) |> st_intersection(cty_p)

# B. Rivers (HydroRIVERS, width from stream order)
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

# C. Cities (Natural Earth populated places → biggest N in Spain)
if (!file.exists("ne_cities/ne_10m_populated_places.shp")) {
  cu <- "https://naciscdn.org/naturalearth/10m/cultural/ne_10m_populated_places.zip"
  download.file(cu, basename(cu), mode = "wb"); unzip(basename(cu), exdir = "ne_cities")
}
cities <- st_read("ne_cities/ne_10m_populated_places.shp", quiet = TRUE) |>
  filter(ADM0NAME == "Spain") |>
  st_transform(CRS_PROJ) |> st_intersection(cty_p) |>
  mutate(is_cap = FEATURECLA |> str_detect("capital"),
         label  = NAME) |>
  arrange(desc(is_cap), desc(POP_MAX)) |>
  slice_head(n = N_CITIES)

# ---- assemble overlays (order matters: water under ink under towns) ----
ext_s <- dem_relief_s                      # extent object for overlay georeferencing

final_map <- tex |>
  add_shadow(ray, max_darken = 0.42) |>
  add_shadow(amb, max_darken = 0.22) |>
  add_overlay(generate_polygon_overlay(lakes, extent = ext_s, heightmap = m,
                                        palette = "#77A9A0", linewidth = 0),
              alphalayer = 0.9) |>
  add_overlay(generate_line_overlay(rivers, extent = ext_s, heightmap = m,
                                    color = "#4E8B80", linewidth = rivers$width,
                                    data_column_width = "width"),
              alphalayer = 0.85) |>
  add_overlay(generate_line_overlay(st_cast(cty_p, "MULTILINESTRING"),
                                    extent = ext_s, heightmap = m,
                                    color = "#5E5140", linewidth = 2),
              alphalayer = 0.85) |>
  # city dots
  add_overlay(generate_point_overlay(cities, extent = ext_s, heightmap = m,
                                     color = "#3E3120", size = 3, pch = 19),
              alphalayer = 0.95)

# city labels — generate_label_overlay is the rayshader-native, correctly
# projected way. Guarded (function may be absent / have a different signature
# on older rayshader) so a mismatch degrades to dots-only, never aborts.
final_map <- tryCatch(
  final_map |>
    add_overlay(rayshader::generate_label_overlay(
      cities, extent = ext_s, heightmap = m, text_size = 1.5, point_size = 0,
      color = "#3E3120", halo_color = "#F4F1E7", halo_expand = 3,
      font = 2, data_label_column = "label", seed = 1),
      alphalayer = 1),
  error = function(e) {
    message("generate_label_overlay unavailable (", conditionMessage(e),
            ") — dots drawn without labels.")
    final_map
  })

# quick sanity check before the (slower) 3D render
rayshader::plot_map(final_map)

# 8. 3D SCENE + HIGH-QUALITY RENDER --------------------------
# aspect-correct render size, long side = RENDER_MAX
asp <- diff(frame_bbox[c(1, 3)]) / diff(frame_bbox[c(2, 4)])   # width / height
if (asp >= 1) { rw <- RENDER_MAX; rh <- round(RENDER_MAX / asp)
} else        { rh <- RENDER_MAX; rw <- round(RENDER_MAX * asp) }

rayshader::plot_3d(
  final_map, m,
  zscale = ZSCALE,
  solid = FALSE,
  shadow = FALSE,                 # ray_shade already provides the drop shadow
  background = "#F5F1E6",
  windowsize = c(round(rw / 2), round(rh / 2)),
  zoom = 0.72, phi = 89, theta = 0
)

rayshader::render_highquality(
  filename = "spain_carta.png",
  preview  = FALSE,
  light    = FALSE,
  environment_light = hdri_file,
  intensity_env = 1.15,
  interactive = FALSE,
  width = rw, height = rh,
  samples = 256
  # line_antialias = TRUE
)

# 9. VINTAGE FURNISHING (magick) -----------------------------
stopifnot(file.exists("spain_carta.png"))
# check fonts if Playfair falls back:  print(magick::magick_fonts(), n = 200)
raw <- image_read("spain_carta.png")
W <- image_info(raw)$width; H <- image_info(raw)$height

plate <- raw |>
  image_annotate("COMISIÓN DEL SERVICIO GEOLÓGICO", font = "Playfair Display",
                 size = round(H * 0.020), gravity = "northwest",
                 location = paste0("+", round(W*0.05), "+", round(H*0.06)),
                 color = "#4A3B28", kerning = 6) |>
  image_annotate("CARTA HIPSOMÉTRICA", font = "Playfair Display",
                 size = round(H * 0.036), gravity = "northwest",
                 location = paste0("+", round(W*0.05), "+", round(H*0.095)),
                 color = "#4A3B28", kerning = 10) |>
  image_annotate("D E", font = "Playfair Display", size = round(H * 0.018),
                 gravity = "northwest",
                 location = paste0("+", round(W*0.05), "+", round(H*0.145)),
                 color = "#6B5B45") |>
  image_annotate("ESPAÑA", font = "Playfair Display", weight = 700,
                 size = round(H * 0.075), gravity = "northwest",
                 location = paste0("+", round(W*0.05), "+", round(H*0.165)),
                 color = "#3E3120") |>
  image_annotate("(según la carta corográfica a escala 1:500 000)",
                 size = round(H * 0.015), gravity = "northwest",
                 location = paste0("+", round(W*0.05), "+", round(H*0.255)),
                 color = "#6B5B45") |>
  image_annotate("1906", font = "Playfair Display", size = round(H * 0.022),
                 gravity = "northwest",
                 location = paste0("+", round(W*0.05), "+", round(H*0.285)),
                 color = "#4A3B28") |>
  # neighbour & sea labels (letterpress grey), roughly placed
  image_annotate("P O R T U G A L", size = round(H*0.026), degrees = 90, kerning = 14,
                 gravity = "west", location = paste0("+", round(W*0.02), "+", round(H*0.05)),
                 color = "#B9B2A2") |>
  image_annotate("F R A N C I A", size = round(H*0.026), kerning = 14,
                 gravity = "north", location = paste0("+", round(W*0.15), "+", round(H*0.02)),
                 color = "#B9B2A2") |>
  image_annotate("M A R   M E D I T E R R Á N E O", size = round(H*0.022), kerning = 8,
                 gravity = "southeast", location = paste0("+", round(W*0.06), "+", round(H*0.10)),
                 color = "#8FB3AC")

# legend swatch (hypsometric ramp)
sw <- image_graph(180, 300, res = 96); par(mar = c(0, 0, 0, 0))
image(1, seq_len(12), t(matrix(1:12)),
      col = rev(hypso[seq(1, 512, length.out = 12)]),
      axes = FALSE, xlab = "", ylab = ""); box(col = "#6B5B45"); dev.off()
plate <- image_composite(plate, sw, offset = paste0("+", round(W*0.06), "+", H - 380))
plate <- image_annotate(plate, "LEYENDA", font = "Playfair Display",
                        size = round(H * 0.018), gravity = "southwest",
                        location = paste0("+", round(W*0.06), "+", 400),
                        color = "#4A3B28", kerning = 6)

final <- image_border(plate, "#EDEAE2", "90x90")
image_write(final, "spain_carta_final.png", quality = 97)

cat("\nDone → spain_carta_final.png (", W, "x", H, ")\n")
cat("Tune next time: ZSCALE (relief drama), Z_LEVEL (detail), N_CITIES, label positions.\n")
