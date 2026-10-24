library(sf)
library(rayshader)
library(tidyverse)
library(R.utils)
library(stars)


# load geo data

crsLAEA <- "+proj=laea +lat_0=52 +lon_0=10 +x_0=4321000 +y_0=3210000 +datum=WGS84 +units=m +no_defs"
f_data <- st_read("kontur_population_FR_20231101.gpkg")
f_data_transformed <- st_transform(f_data, crs = crsLAEA)

head(f_data)

ggplot() + geom_sf(data = f_data_transformed, color = "grey10", fill = "grey10")

bb <- sf::st_bbox(f_data_transformed)

print(sf::st_bbox(f_data_transformed))

# Calculate centroids for each geometry
centroids <- sf::st_centroid(f_data_transformed)

# Find the centroid closest to mainland France (approximate LAEA coordinates for Paris)
paris_coords <- matrix(c(2550000, 1900000), ncol = 2)
paris_point <- sf::st_sfc(sf::st_point(paris_coords), crs = sf::st_crs(centroids))
distances <- sf::st_distance(centroids, paris_point)

# Select features within a reasonable distance from Paris (e.g., < 1,000,000 meters)
mainland_idx <- which(as.numeric(distances) < 3000000)
f_data_mainland <- f_data_transformed[mainland_idx, ]

fr_bbox <- sf::st_bbox(f_data_mainland)
print(fr_bbox)

# bb_check <- ggplot() +
#   geom_sf(data = f_data_transformed, color = "grey10", fill = "grey90") +
#   geom_rect(
#     aes(xmin = 800000, xmax = 3000000, ymin = 1200000, ymax = 2500000),
#     fill = NA, color = "red", linewidth = 1
#   )

# ggsave("bb_check.png", bb_check)

continental_bbox <- fr_bbox

# Crop the data
f_data_continental <- sf::st_crop(f_data_transformed, continental_bbox)

# Diagnostic: check if crop worked
# if (nrow(f_data_continental) == 0) {
#     stop("Crop returned no features. Adjust continental_bbox coordinates.")
# }

ggplot() + geom_sf(data = f_data_continental, color = "grey10", fill = "grey10")

get_raster_size <- function() {
    height <- sf::st_distance(
        sf::st_point(c(bb[["xmin"]], bb[["ymin"]])),
        sf::st_point(c(bb[["xmin"]], bb[["ymax"]]))
    )
    width <- sf::st_distance(
        sf::st_point(c(bb[["xmin"]], bb[["ymin"]])),
        sf::st_point(c(bb[["xmax"]], bb[["ymin"]]))
    )

    if (height > width) {
        height_ratio <- 1
        width_ratio <- width / height
    } else {
        width_ratio <- 1
        height_ratio <- height / width
    }

    return(list(width_ratio, height_ratio))
}
width_ratio <- get_raster_size()[[1]]
height_ratio <- get_raster_size()[[2]]

size <- 3000
width <- round((size * width_ratio), 0)
height <- round((size * height_ratio), 0)

pop_rast <- stars::st_rasterize(
  f_data_continental |> dplyr::select(population, geom),
  nx = width, ny = height
    )

pop_rast <- get_population_raster()
plot(pop_rast)

pop_mat <- pop_rast |>
    as("Raster") |>
    rayshader::raster_to_matrix()

cols <- rev(c(
    "#0b1354", "#283680",
    "#6853a9", "#c863b3"
))

texture <- grDevices::colorRampPalette(cols)(256)

# Create the initial 3D object
pop_mat |>
    rayshader::height_shade(texture = texture) |>
    rayshader::plot_3d(
        heightmap = pop_mat,
        solid = F,
        soliddepth = 0,
        zscale = 65,
        shadowdepth = 0,
        shadow_darkness = .75,
        windowsize = c(800, 800),
        phi = 45,
        zoom = .85,
        theta = -10,
        background = "white"
    )

# Use this to adjust the view after building the window object
rayshader::render_camera(phi = 45, zoom = .6, theta = 0)

rayshader::render_highquality(
    filename = "france_population_2023.png",
    preview = T,
    light = T,
    lightdirection = 225,
    lightaltitude = 60,
    lightintensity = 400,
    interactive = F,
    width = width, height = height
)
