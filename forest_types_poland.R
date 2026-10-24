libs <- c(
    "giscoR",
    "terra",
    "sf",
    "rayshader",
    "elevatr",
    "magick",
    "future"
)

installed_Libs <- libs %in% rownames(
  installed.packages()
)

if(any(!installed_Libs == FALSE)) {
  install.packages(libs[!installed_Libs])
}

invisible(lapply(libs[!installed_Libs], install.packages))

invisible(lapply(libs, library, character.only = TRUE))

# COUNTRY BOUNDS
#---------------------------

country_sf <- gisco_get_countries(
  country = "PL",
  resolution = "1"
)

options(timeout = max(1800, getOption("timeout")))

url <- "https://zenodo.org/records/3939050/files/PROBAV_LC100_global_v3.0.1_2019-nrt_Forest-Type-layer_EPSG-4326.tif?download=1"
download.file(url, destfile = "forest_type_poland_2019.tif", mode = "wb")

forest_type <- rast(
  basename("forest_type_poland_2019.tif")
)

forest_type

vals <- values(forest_type,
  dataframe = TRUE
)
names(vals)
names(vals)[1] <- "value"
unique(vals$value)

# 3. CROP FOREST TYPE RASTER
#---------------------------

crs_lambert <-
    "+proj=laea +lat_0=52 +lon_0=10 +x_0=4321000 +y_0=3210000 +datum=WGS84 +units=m +no_frfs"

country_forest_type <- crop(forest_type, 
  vect(country_sf),
  snap = "in",
  mask = TRUE
)

terra::project(country_forest_type, crs_lambert)
terra::plot(country_forest_type)

cols <- c(
"#120D31", 
"#302F4D", 
# "#A57982", 
"#B98EA7", 
"#F0D3F7"
)

from <- c(0:1, 4:5)
to <- t(col2rgb(cols))

forest_terra <- na.omit(
  country_forest_type
)

forest_type_image <- subst(
  forest_terra,
  from = from,
  to = to,
  names = cols
)

plotRGB(forest_type_image)

img_file <- "poland_forest_type.png"
writeRaster(
  forest_type_image,
  filename = img_file,
  overwrite = TRUE
)

elev <- get_elev_raster(
  locations = country_sf,
  z = 10, clip = "locations"
)

elev_lambert <- elev |>
  rast() |>
  project(crs_lambert)

elmat <- raster_to_matrix(
  elev_lambert
)

elmat |>
  height_shade(
    texture = colorRampPalette(
      "white"
    )(512)
  ) |>
  add_overlay(
    img,
    alphalayer = .85,
    alphacolor = "white"
  ) |>
  add_shadow(
    lamb_shade(
      elmat,
      zscale = 50,
      sunaltitude = 90,
      sunangle  = 315
    ), max_darken = .25
  ) |>
  add_shadow(
    texture_shade(
      elmat,
      detail = .95,
      brightness = 90,
      contrast = 85
    ), max_darken = .1
  ) |>
  plot_3d(
    elmat,
    zscale = 5,
    solid = FALSE,
    shadow = TRUE,
    shadow_darkness = 1,
    background = "white",
    zoom = .5,
    phi = 85,
    theta = 0
  )

url_light <- "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/river_alcove_4k.hdr"
download.file(url_light, destfile = "river_alcove_4k.hdr", mode = "wb")

  render_highquality(
    filename = "poland_forest_type_3d.png",
    preview = TRUE,
    light = FALSE,
    environment_light = "river_alcove_4k.hdr",
    intensivity_env = 2,
    rotate_env = 90,
    interactive = FALSE,
    parallel = TRUE
  )

dim(elmat)
object.size(elmat) / 1024^2   # MB

# MISC  

# # 1) Crop + mask to Poland then get category frequencies (fast and on-disk)
# freq_in_poland <- function(rast, country_sf) {
#   country_vect <- vect(country_sf)                    # convert sf -> SpatVector
#   r_crop <- crop(rast, ext(country_sf))              # crop to bounding box
#   r_mask <- mask(r_crop, country_vect)                # mask to country shape
#   terra::freq(r_mask, digits = 0)                     # returns categories + counts (no full read)
# }
# # Usage:
# # freq_res <- freq_in_poland(forest_type, country_sf)


# # 2) Block-wise reading and accumulating counts (robust, low memory)
# block_freq <- function(rast, chunk_rows = 2000) {
#   counts <- numeric()                                 # named numeric vector for counts
#   terra::readStart(rast)
#   on.exit(terra::readStop(rast), add = TRUE)
#   total_rows <- nrow(rast)
#   for (start in seq(1, total_rows, by = chunk_rows)) {
#     nrows <- min(chunk_rows, total_rows - start + 1)
#     vals <- terra::readValues(rast, row = start, nrows = nrows)
#     vals <- as.vector(vals)
#     vals <- vals[!is.na(vals)]
#     if (length(vals) == 0) next
#     t <- table(vals)
#     for (nm in names(t)) {
#       counts[nm] <- counts[nm] + as.integer(t[[nm]])
#     }
#   }
#   # return data.frame with numeric category and count
#   res <- data.frame(
#     value = as.numeric(names(counts)),
#     count = as.numeric(counts),
#     row.names = NULL
#   )
#   res[order(-res$count), , drop = FALSE]
# }
# # Usage:
# # blk_freq <- block_freq(forest_type, chunk_rows = 2000)


# # 3) Random sampling (if you only need a representative subset)
# sample_values <- function(rast, n = 20000, seed = 42) {
#   set.seed(seed)
#   s <- terra::spatSample(rast, size = n, method = "random", as.data.frame = TRUE, na.rm = TRUE)
#   # s is a data.frame with sampled cell values; return for downstream modelling/plots
#   s
# }
# # Usage:
# # sample_df <- sample_values(forest_type, n = 10000)


# # 4) Aggregate to coarser resolution and then inspect (reduces memory)
# agg_modal <- function(rast, fact = 10, out_file = tempfile(fileext = ".tif")) {
#   # modal = most frequent value in block; use filename to write on-disk
#   r_ag <- terra::aggregate(rast, fact = fact, fun = modal, filename = out_file, overwrite = TRUE)
#   r_ag                                      # return aggregated SpatRaster (much smaller)
# }
# # Usage:
# # coarse <- agg_modal(forest_type, fact = 50)


# # Example workflow for Poland (safe default):
# # 1. try cropped freq
# # freq_res <- freq_in_poland(forest_type, country_sf)
# # if that still runs out of memory, try block_freq on the cropped raster:
# # r_pol <- mask(crop(forest_type, ext(country_sf)), vect(country_sf))
# # pol_counts <- block_freq(r_pol, chunk_rows = 2000)

# # Each function returns an object you can inspect/manipulate (no global print).
