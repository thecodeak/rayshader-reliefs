# ============================================================
# HYPSOMETRIC RELIEF ON A VINTAGE PAPER BASEMAP — NORWAY
# 3D relief inside the country, flat "paper" surroundings
# ============================================================

# 1. SETUP ---------------------------------------------------
if (!require("pacman")) install.packages("pacman")
pacman::p_load(terra, elevatr, sf, geodata, tidyverse, rayshader, magick)

sf::sf_use_s2(FALSE)
crs_utm33 <- "EPSG:25833"

# HDRI for the studio lighting (download once)
u <- "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/photo_studio_loft_hall_4k.hdr"
hdri_file <- basename(u)
if (!file.exists(hdri_file)) download.file(u, hdri_file, mode = "wb")

# 2. GEOMETRY ------------------------------------------------
norway <- geodata::gadm("NOR", level = 0, path = getwd()) |> sf::st_as_sf()

# Keep mainland + coastal islands, drop Svalbard / Jan Mayen / Bear Island
nor_parts <- sf::st_cast(norway, "POLYGON") |> sf::st_make_valid()
cent      <- sf::st_coordinates(sf::st_centroid(nor_parts))
mainland  <- nor_parts[cent[, 2] < 72 & cent[, 1] > 4, ] |>
  sf::st_union() |> sf::st_as_sf() |> sf::st_make_valid()

nor_proj <- sf::st_transform(mainland, crs_utm33)

# Frame = country + margin (the "paper")
frame_bbox <- sf::st_bbox(nor_proj) + c(-200000, -150000, 200000, 150000)
frame_sf   <- sf::st_as_sfc(frame_bbox) |> sf::st_set_crs(crs_utm33)

# Neighbouring land for the paper texture
neigh <- lapply(c("SWE", "FIN", "RUS"), \(x)
                geodata::gadm(x, level = 0, path = getwd()) |> sf::st_as_sf()) |>
  dplyr::bind_rows() |>
  sf::st_transform(crs_utm33) |>
  sf::st_make_valid() |>
  sf::st_intersection(frame_sf)

# 3. DEM FOR THE WHOLE FRAME ---------------------------------
dem <- elevatr::get_elev_raster(
  locations = sf::st_transform(frame_sf, 4326) |> sf::st_as_sf(),
  z = 6
)

dem <- terra::rast(dem) |>
  terra::project(crs_utm33) |>
  terra::crop(terra::vect(frame_sf))

# force square pixels
res_t <- mean(terra::res(dem))
dem <- terra::resample(
  dem,
  terra::rast(extent = terra::ext(dem), crs = crs_utm33, resolution = res_t)
)

# 4. MASK & FLATTEN ------------------------------------------
mask_r  <- terra::rasterize(terra::vect(nor_proj), dem)   # 1 inside Norway
neigh_r <- terra::rasterize(terra::vect(neigh),    dem)   # 1 on neighbour land

dem_relief <- dem
dem_relief[is.na(mask_r)]  <- 0     # flatten everything outside Norway
dem_relief[dem_relief < 0] <- 0     # kill bathymetry

# Downsize for tractable shading
m <- rayshader::raster_to_matrix(dem_relief)
cat("Raw matrix dims:", dim(m), "\n")

target_max <- 1500
sc <- min(1, target_max / max(dim(m)))

m       <- rayshader::resize_matrix(m, scale = sc)
m_mask  <- rayshader::resize_matrix(rayshader::raster_to_matrix(mask_r),  scale = sc)
m_neigh <- rayshader::resize_matrix(rayshader::raster_to_matrix(neigh_r), scale = sc)

# resizing interpolates → re-binarise the masks
m_mask[!is.na(m_mask)   & m_mask  < 0.5] <- NA
m_neigh[!is.na(m_neigh) & m_neigh < 0.5] <- NA

cat("Final matrix dims:", dim(m), "\n")

# 5. TWO-ZONE TEXTURE ----------------------------------------
hypso <- colorRampPalette(
  c("#EDE6D4", "#E3CFA5", "#D3A566", "#C08145", "#8F5A2B")
)(256)

tex <- rayshader::height_shade(m, texture = hypso)

sea_col  <- grDevices::col2rgb("#CFE3DA") / 255   # pale celadon sea
land_col <- grDevices::col2rgb("#F1EDE2") / 255   # warm paper (neighbours)

for (i in 1:3) {
  ch <- tex[, , i]
  ch[is.na(m_mask)] <- sea_col[i]
  ch[is.na(m_mask) & !is.na(m_neigh)] <- land_col[i]
  tex[, , i] <- ch
}

# 6. SHADING -------------------------------------------------
ray <- rayshader::ray_shade(m, zscale = 25, sunaltitude = 35,
                            sunangle = 315, multicore = TRUE)
amb <- rayshader::ambient_shade(m, zscale = 25, maxsearch = 30,
                                multicore = TRUE)

final_map <- tex |>
  rayshader::add_shadow(ray, max_darken = 0.55) |>
  rayshader::add_shadow(amb, max_darken = 0.35) |>
  # engraved coastline / border ink line
  rayshader::add_overlay(
    rayshader::generate_line_overlay(
      sf::st_cast(nor_proj, "MULTILINESTRING"),
      extent = dem_relief, heightmap = m,
      color = "#6B5B45", linewidth = 2
    ),
    alphalayer = 0.9
  )

# 7. 3D SCENE + HIGH-QUALITY RENDER --------------------------
rayshader::plot_3d(
  final_map, m,
  zscale = 25,
  solid = FALSE,
  shadow = FALSE,          # ray_shade already provides the drop shadow
  background = "#F5F1E6",
  windowsize = c(900, 1200),
  zoom = 0.70,
  phi = 89, theta = 0
)

rayshader::render_highquality(
  filename = "norway_carta.png",
  preview  = FALSE,
  light    = FALSE,
  environment_light = hdri_file,
  intensity_env = 1.15,
  interactive = FALSE,
  width = 3000, height = 4000,
  samples = 256                     # sobol_blue cap
)

# 8. VINTAGE FURNISHING (post-process) -----------------------
stopifnot(file.exists("norway_carta.png"))   # fail early if render didn't write

# check available font names if typography falls back:
# print(magick::magick_fonts(), n = 200)

img <- magick::image_read("norway_carta.png") |>
  magick::image_annotate("CARTA HYPSOMETRICA",
                         font = "Playfair Display", size = 90,
                         gravity = "northwest", location = "+250+350",
                         color = "#4A3B28") |>
  magick::image_annotate("DA  NORUEGA",
                         font = "Playfair Display", weight = 700, size = 160,
                         gravity = "northwest", location = "+250+470",
                         color = "#4A3B28") |>
  magick::image_annotate("S V E R I G E",
                         size = 70, degrees = 75,
                         gravity = "east", location = "+300+0",
                         color = "#B9B2A2")

magick::image_write(img, "norway_carta_final.png")