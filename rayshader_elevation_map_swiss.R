# 1. LIBRARIES & SETUP
#---------------------
if (!require("pacman")) install.packages("pacman")
pacman::p_load(terra, elevatr, sf, geodata, tidyverse, rayshader, raster)

# Turn off spherical geometry for cleaner clipping
sf::sf_use_s2(FALSE) 

# 2. COUNTRY BORDERS
#-------------------
country_sf <- geodata::gadm(country = "CHE", level = 0, path = getwd()) |>
    sf::st_as_sf()

crs_country <- "+proj=somerc +lat_0=46.9524055555556 +lon_0=7.43958333333333 +k_0=1 +x_0=600000 +y_0=200000 +ellps=bessel +towgs84=674.374,15.056,405.346,0,0,0,0 +units=m +no_defs +type=crs"

# 3. PREPARE DEM (SQUARE PIXELS)
#-------------------------------
dem <- elevatr::get_elev_raster(locations = country_sf, z = 10, clip = "locations")

# Force square pixels to prevent "squishing"
dem_country_raw <- dem |> terra::rast() |> terra::project(crs_country)
target_res <- mean(terra::res(dem_country_raw)) 
dem_country <- terra::resample(
    dem_country_raw, 
    terra::rast(extent = terra::ext(dem_country_raw), crs = crs_country, resolution = target_res)
)

dem_matrix <- rayshader::raster_to_matrix(dem_country)
dem_matrix_small <- rayshader::resize_matrix(dem_matrix, scale = 0.5)

# 4. PREPARE WATER (RIVERS & LAKES)
#----------------------------------

# A. RIVERS (Existing logic)
if (!file.exists("HydroRIVERS_v10_eu_shp/HydroRIVERS_v10_eu.shp")) {
    url <- "https://data.hydrosheds.org/file/HydroRIVERS/HydroRIVERS_v10_eu_shp.zip"
    download.file(url, basename(url), mode = "wb")
    unzip(basename(url))
}
rivers_file <- list.files(path = "HydroRIVERS_v10_eu_shp", pattern = ".shp", full.names = TRUE)
country_rivers <- sf::st_read(rivers_file, wkt_filter = st_as_text(st_as_sfc(st_bbox(country_sf)))) |>
    sf::st_intersection(country_sf) |>
    sf::st_transform(crs_country)

# Refine River Widths
country_river_width <- country_rivers |>
    dplyr::mutate(
        width = as.numeric(ORD_FLOW),
        width = dplyr::case_when(
            width == 3 ~ 6, width == 4 ~ 4, width == 5 ~ 3, 
            width == 6 ~ 2, width == 7 ~ 1, TRUE ~ 0
        )
    ) |>
    dplyr::filter(width > 0)

# B. LAKES (New Logic)
# We download Natural Earth 10m Lakes
lake_url <- "https://www.naturalearthdata.com/http//www.naturalearthdata.com/download/10m/physical/ne_10m_lakes.zip"
lake_file <- basename(lake_url)
if (!file.exists(lake_file)) {
    download.file(lake_url, lake_file, mode = "wb")
    unzip(lake_file, exdir = "ne_lakes")
}

# Load and Clip Lakes
lakes_sf <- sf::st_read("ne_lakes/ne_10m_lakes.shp") |>
    sf::st_transform(crs_country) |>
    sf::st_intersection(country_sf) # Clip to Swiss border

# 5. TEXTURE & SHADING
#---------------------
colors_low <- colorRampPalette(c("#2E4032", "#6B7F48"))(51) 
colors_mid <- colorRampPalette(c("#6B7F48", "#918E7B"))(51)
colors_high <- colorRampPalette(c("#918E7B", "#4F4F4F"))(77)
colors_peak <- colorRampPalette(c("#D6D6D6", "#FFFFFF"))(77)
alpine_texture <- c(colors_low, colors_mid, colors_high, colors_peak)

texture_map <- rayshader::height_shade(dem_matrix_small, texture = alpine_texture)

# Shadows
ray_layer <- rayshader::ray_shade(dem_matrix_small, zscale = 12, multicore = TRUE)
amb_layer <- rayshader::ambient_shade(dem_matrix_small, zscale = 12, multicore = TRUE)

# 6. COMPOSITE OVERLAYS (Lakes + Rivers)
#---------------------------------------
# We add lakes FIRST (so rivers flow over them if they overlap)
final_map <- texture_map |>
    rayshader::add_shadow(ray_layer, max_darken = 0.5) |>
    rayshader::add_shadow(amb_layer, max_darken = 0.3) |>
    # Add Lakes (Polygon Overlay)
    rayshader::add_overlay(
        rayshader::generate_polygon_overlay(
            geometry = lakes_sf,
            extent = dem_country,
            heightmap = dem_matrix_small,
            linecolor = "#387B9C",
            linewidth = 0,
            palette = "#387B9C" # Lake Color
        ), alphalayer = 1
    ) |>
    # Add Rivers (Line Overlay)
    rayshader::add_overlay(
        rayshader::generate_line_overlay(
            geometry = country_river_width,
            extent = dem_country,
            heightmap = dem_matrix_small,
            color = "#387B9C",
            linewidth = country_river_width$width,
            data_column_width = "width"
        ), alphalayer = 1
    )

# 7. PLOT 3D
#-----------
rayshader::plot_3d(
    final_map,
    dem_matrix_small,
    zscale = 12,
    solid = FALSE,
    shadow = TRUE,
    shadow_darkness = 1,
    background = "white",
    windowsize = c(1000, 1000), # Square window
    zoom = 0.80,
    phi = 89,
    theta = 0
)

# 8. RENDER HIGH QUALITY
#-----------------------
u <- "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/photo_studio_loft_hall_4k.hdr"
hdri_file <- basename(u)
if (!file.exists(hdri_file)) download.file(u, destfile = hdri_file, mode = "wb")

rayshader::render_highquality(
    filename = "switzerland_final_lakes.png",
    preview = FALSE,           # <--- Set to FALSE to prevent render glitches
    light = FALSE,
    environment_light = hdri_file,
    intensity_env = 1.2,
    interactive = FALSE,
    width = 3500,
    height = 3500,
    samples = 350,             # Slightly higher quality
    line_antialias = TRUE      # Smooths out the river lines
)