library(sf)
library(rayshader)
library(tidyverse)
library(R.utils)
library(stars)


# load geo data

crsLAEA <- "+proj=laea +lat_0=52 +lon_0=10 +x_0=4321000 +y_0=3210000 +datum=WGS84 +units=m +no_defs"
nr_data <- st_read("kontur_population_NO_20231101.gpkg")
nr_data_transformed <- st_transform(nr_data, crs = crsLAEA)

head(nr_data)
str(nr_data_transformed)
view(nr_data, n = 500)

ggplot() + geom_sf(data = nr_data_transformed, color = "grey10", fill = "grey10")

bb <- sf::st_bbox(nr_data_transformed)

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

get_population_raster <- function() {
    pop_rast <- stars::st_rasterize(
        nr_data_transformed |>
            dplyr::select(population, geom),
        nx = width, ny = height
    )

    return(pop_rast)
}

pop_rast <- get_population_raster()
plot(pop_rast)

pop_mat <- pop_rast |>
    as("Raster") |>
    rayshader::raster_to_matrix()

cols <- rev(c(
    "#540b0bff", "#571a1aff",
    "#e52525ff", "#ff0000ff"
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
rayshader::render_camera(phi = 45, zoom = .55, theta = 0)

rayshader::render_highquality(
    filename = "norway_population_2023.png",
    preview = T,
    light = T,
    lightdirection = 225,
    lightaltitude = 60,
    lightintensity = 400,
    interactive = F,
    width = width, height = height
)
