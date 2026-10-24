# ============================================================
# "CARTA IPSOMETRICA" — vintage relief-on-paper, Italy
# Debugged: (1) resample-averaging instead of resize_matrix
#           (2) NA-coverage-aware sea/land painting
#           (3) higher sun + lighter shadow stacking
# ============================================================
if (!require("pacman")) install.packages("pacman")
pacman::p_load(terra, elevatr, sf, geodata, tidyverse, rayshader, magick, lwgeom)

sf::sf_use_s2(FALSE)

# ---- PARAMETERS --------------------------------------------
ISO        <- "ITA"
NEIGH      <- c("FRA", "CHE", "AUT", "SVN", "HRV", "TUN", "ALB", "SMR", "VAT")
CRS_PROJ   <- "EPSG:32633"           # UTM33N fits Italy well
Z_LEVEL    <- 8                      # elevatr zoom; 8 ~ high detail
TARGET_MAX <- 4000                   # matrix long side, post-aggregation
ZSCALE     <- 12
MARGIN     <- c(-120000, -120000, 120000, 120000)

# ---- 1. GEOMETRY -------------------------------------------
cty <- geodata::gadm(ISO, level = 0, path = getwd()) |> st_as_sf() |> st_make_valid()

# keep only substantial landmasses (drops micro-islets that add noise)
parts <- st_cast(cty, "POLYGON") |> st_make_valid()
parts <- parts[as.numeric(st_area(parts)) > 5e7, ]        # > 50 km^2
cty   <- st_union(parts) |> st_as_sf() |> st_make_valid()
cty_p <- st_transform(cty, CRS_PROJ)

frame_bbox <- st_bbox(cty_p) + MARGIN
frame_sf   <- st_as_sfc(frame_bbox) |> st_set_crs(CRS_PROJ)
frame_ll   <- st_transform(frame_sf, 4326)

neigh <- lapply(NEIGH, \(x) tryCatch(
           geodata::gadm(x, 0, path = getwd()) |> st_as_sf(), error = \(e) NULL)) |>
  compact() |> bind_rows() |> st_make_valid() |>
  st_transform(CRS_PROJ) |> st_intersection(frame_sf) |> st_make_valid()

# ---- 2. DEM (high res) -------------------------------------
dem_raw <- elevatr::get_elev_raster(st_as_sf(frame_ll), z = Z_LEVEL) |>
  terra::rast() |> terra::project(CRS_PROJ) |> terra::crop(terra::vect(frame_sf))

res_t <- mean(terra::res(dem_raw))
dem <- terra::resample(dem_raw, terra::rast(extent = terra::ext(dem_raw),
                                            crs = CRS_PROJ, resolution = res_t))

mask_r  <- terra::rasterize(terra::vect(cty_p),  dem)
neigh_r <- terra::rasterize(terra::vect(neigh),  dem)

# ---- 3. RELIEF + FLAT PAPER SURFACES ------------------------
dem_relief <- dem
dem_relief[is.na(mask_r)]  <- 0
dem_relief[dem_relief < 0] <- 0

bath <- dem
bath[bath >= 0] <- NA

# FIX #2: downsample via terra::aggregate (area-averaging) instead of
# rayshader::resize_matrix (which produced Moire/vertical striping)
long_side  <- max(dim(dem_relief)[1:2])
agg_factor <- max(1, round(long_side / TARGET_MAX))

dem_relief_small <- terra::aggregate(dem_relief, fact = agg_factor, fun = "mean")
mask_r_small     <- terra::aggregate(mask_r,     fact = agg_factor, fun = "modal")
neigh_r_small    <- terra::aggregate(neigh_r,    fact = agg_factor, fun = "modal")
bath_small       <- terra::aggregate(bath,       fact = agg_factor, fun = "mean")
dem_small        <- terra::aggregate(dem,        fact = agg_factor, fun = "mean")

m       <- rayshader::raster_to_matrix(dem_relief_small)
m_mask  <- rayshader::raster_to_matrix(mask_r_small)
m_neigh <- rayshader::raster_to_matrix(neigh_r_small)
m_bath  <- rayshader::raster_to_matrix(bath_small)
m_dem   <- rayshader::raster_to_matrix(dem_small)      # for NA-coverage check

cat("matrix:", dim(m), "  (agg_factor =", agg_factor, ")\n")
stopifnot(identical(dim(m), dim(m_mask)), identical(dim(m), dim(m_dem)))

# ---- 4. HYDROGRAPHY (the engraving) ------------------------
if (!file.exists("HydroRIVERS_v10_eu_shp/HydroRIVERS_v10_eu.shp")) {
  ru <- "https://data.hydrosheds.org/file/HydroRIVERS/HydroRIVERS_v10_eu_shp.zip"
  download.file(ru, basename(ru), mode = "wb"); unzip(basename(ru))
}
rivers <- st_read(list.files("HydroRIVERS_v10_eu_shp", "\\.shp$", full.names = TRUE),
                  wkt_filter = st_as_text(st_as_sfc(st_bbox(frame_ll))), quiet = TRUE) |>
  st_intersection(cty) |> st_transform(CRS_PROJ) |>
  mutate(w = as.numeric(ORD_FLOW),
         width = case_when(w <= 3 ~ 4.5, w == 4 ~ 3.2, w == 5 ~ 2.2,
                           w == 6 ~ 1.5, w == 7 ~ 1.0, w == 8 ~ 0.6,
                           w == 9 ~ 0.35, TRUE ~ 0)) |>
  filter(width > 0)

lu <- "https://naciscdn.org/naturalearth/10m/physical/ne_10m_lakes.zip"
if (!dir.exists("ne_lakes")) { download.file(lu, basename(lu), mode = "wb")
                               unzip(basename(lu), exdir = "ne_lakes") }
lakes <- st_read("ne_lakes/ne_10m_lakes.shp", quiet = TRUE) |> st_make_valid() |>
  st_transform(CRS_PROJ) |> st_intersection(cty_p)

# ---- 5. PALETTE: non-linear hypsometric --------------------
hypso_stops <- c("#E9E4D6", "#DCDCC6", "#CFC9A4", "#C9B27C",
                 "#C2914F", "#B4712F", "#96541F", "#6F3C18")
pos   <- c(0, .04, .09, .17, .30, .48, .72, 1)^0.75
hypso <- grDevices::colorRamp(hypso_stops)(pos) |> rgb(maxColorValue = 255) |>
         colorRampPalette()
hypso <- hypso(512)

tex <- rayshader::height_shade(m, texture = hypso)

# ---- 6. PAINT THE FLAT ZONE (FIX #3: NA-coverage aware) -----
sea_shal <- col2rgb("#C9E0D8") / 255     # shelf
sea_deep <- col2rgb("#AFCFC9") / 255     # deep
land_pap <- col2rgb("#F4F1E7") / 255     # neighbouring land (near-white paper)

depth  <- pmin(1, abs(pmin(m_bath, 0, na.rm = TRUE)) / 2500)
depth[is.na(depth)] <- 0

# TRUE coverage gap (no DEM data at all after aggregation), distinct from "not in country"
dem_na  <- is.na(m_dem)
outside <- is.na(m_mask) | dem_na

for (i in 1:3) {
  ch <- tex[, , i]
  ch[outside] <- (sea_shal[i] * (1 - depth) + sea_deep[i] * depth)[outside]
  ch[outside & !is.na(m_neigh) & !dem_na] <- land_pap[i]
  # any leftover true coverage gaps: fall back to mid-shelf tone rather than leaving default NA fill
  ch[dem_na] <- sea_shal[i] * 0.9
  tex[, , i] <- ch
}

# ---- 7. SHADING (FIX #1: higher sun, lighter stacking) ------
ray <- ray_shade(m, zscale = ZSCALE, sunaltitude = 45, sunangle = 315, multicore = TRUE)
lam <- lamb_shade(m, zscale = ZSCALE, sunaltitude = 45, sunangle = 315)
amb <- ambient_shade(m, zscale = ZSCALE, maxsearch = 15, multicore = TRUE)

# Helper: guard against any residual off-by-one dims from rayshader internals
match_dims <- function(x, ref) {
  dx <- dim(ref)
  out <- matrix(1, dx[1], dx[2])          # 1 = "no shading" fill value
  nr <- min(nrow(x), dx[1]); nc <- min(ncol(x), dx[2])
  out[1:nr, 1:nc] <- x[1:nr, 1:nc]
  out
}
ray <- match_dims(ray, m); lam <- match_dims(lam, m); amb <- match_dims(amb, m)

graticule <- st_graticule(frame_sf, lon = seq(4, 20, 1), lat = seq(35, 48, 1)) |>
  st_transform(CRS_PROJ)

final_map <- tex |>
  add_shadow(lam, max_darken = 0.35) |>
  add_shadow(ray, max_darken = 0.35) |>
  add_shadow(amb, max_darken = 0.10) |>
  add_overlay(generate_line_overlay(graticule, extent = dem_relief_small, heightmap = m,
                                    color = "#8C8878", linewidth = 1),
              alphalayer = 0.22) |>
  add_overlay(generate_polygon_overlay(lakes, extent = dem_relief_small, heightmap = m,
                                       palette = "#77A9A0", linewidth = 0),
              alphalayer = 0.9) |>
  add_overlay(generate_line_overlay(rivers, extent = dem_relief_small, heightmap = m,
                                    color = "#4E8B80", linewidth = rivers$width,
                                    data_column_width = "width"),
              alphalayer = 0.85) |>
  add_overlay(generate_line_overlay(st_cast(cty_p, "MULTILINESTRING"),
                                    extent = dem_relief_small, heightmap = m,
                                    color = "#5E5140", linewidth = 2),
              alphalayer = 0.85)

# sanity check BEFORE shadow/typography — inspect for striping/seam/greyness
rayshader::plot_map(final_map)

# ---- 8. FAKE DROP SHADOW + BEVEL (pure base R, no rayimage) --
shadow_alpha <- ifelse(is.na(m_mask), 0, 1)          # 1 inside country
off <- max(2, round(max(dim(m)) * 0.006))

# simple box blur via repeated matrix shifting (no rayimage dependency)
box_blur <- function(mat, radius) {
  out <- mat
  for (i in seq_len(radius)) {
    out <- (out +
      rbind(out[-1, , drop = FALSE], out[nrow(out), , drop = FALSE]) +
      rbind(out[1, , drop = FALSE], out[-nrow(out), , drop = FALSE]) +
      cbind(out[, -1, drop = FALSE], out[, ncol(out)]) +
      cbind(out[, 1], out[, -ncol(out), drop = FALSE])) / 5
  }
  out
}

sh <- matrix(0, nrow(shadow_alpha), ncol(shadow_alpha))
ix <- (1 + off):nrow(sh); iy <- 1:(ncol(sh) - off)
sh[ix, iy] <- shadow_alpha[1:(nrow(sh) - off), (1 + off):ncol(sh)]
sh <- box_blur(sh, radius = round(off / 2))
sh[shadow_alpha == 1] <- 0                           # don't darken the country itself
sh <- sh * 0.42

for (i in 1:3) final_map[, , i] <- final_map[, , i] * (1 - sh)

edge <- box_blur(shadow_alpha, radius = max(2, off %/% 2))
rim  <- pmax(0, edge - shadow_alpha) * 0.35
for (i in 1:3) final_map[, , i] <- final_map[, , i] * (1 - rim)

rayshader::save_png(final_map, "carta_raw.png")

# ---- 9. PAPER, FRAME, SHADOW, TYPOGRAPHY (magick) ----------
stopifnot(file.exists("carta_raw.png"))
raw <- image_read("carta_raw.png")
W <- image_info(raw)$width; H <- image_info(raw)$height

grain <- image_blank(W, H, "#FFFFFF") |> image_noise("gaussian") |>
         image_blur(2, 1) |> image_modulate(brightness = 104, saturation = 0)
plate <- raw |>
  image_modulate(saturation = 92, brightness = 101) |>
  image_composite(grain, operator = "multiply")

plate <- plate |>
  image_annotate("COMMISSIONE DEL SERVIZIO GEOLOGICO", font = "Playfair Display",
                 size = 44, gravity = "northwest", location = "+230+300",
                 color = "#4A3B28", kerning = 6) |>
  image_annotate("CARTA IPSOMETRICA", font = "Playfair Display", size = 74,
                 gravity = "northwest", location = "+230+400",
                 color = "#4A3B28", kerning = 10) |>
  image_annotate("D I", font = "Playfair Display", size = 40,
                 gravity = "northwest", location = "+230+500", color = "#6B5B45") |>
  image_annotate("ITALIA", font = "Playfair Display", weight = 700, size = 150,
                 gravity = "northwest", location = "+230+560", color = "#3E3120") |>
  image_annotate("(secondo la carta orografica alla scala di 1:500 000)",
                 size = 34, gravity = "northwest", location = "+230+740",
                 color = "#6B5B45") |>
  image_annotate("1906", font = "Playfair Display", size = 46,
                 gravity = "northwest", location = "+230+800", color = "#4A3B28") |>
  image_annotate("F R A N C I A", size = 66, degrees = 90, kerning = 22,
                 gravity = "northwest", location = "+150+1100", color = "#B9B2A2") |>
  image_annotate("L E G E N D A", font = "Playfair Display", size = 40,
                 gravity = "southwest", location = "+280+520",
                 color = "#4A3B28", kerning = 8)

sw <- image_graph(180, 300, res = 96); par(mar = c(0,0,0,0))
image(1, seq_along(hypso[seq(1, 512, length.out = 12)]),
      t(matrix(1:12)), col = rev(hypso[seq(1, 512, length.out = 12)]),
      axes = FALSE, xlab = "", ylab = ""); box(col = "#6B5B45"); dev.off()
plate <- image_composite(plate, sw, offset = paste0("+320+", H - 480))

final <- image_border(plate, "#EDEAE2", "160x160")

image_write(final, "carta_ipsometrica_italia.png", quality = 97)
