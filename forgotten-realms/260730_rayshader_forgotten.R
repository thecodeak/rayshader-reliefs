# ============================================================
# CARTA HIPSOMETRICA DE LOS REINOS OLVIDADOS
# "Forgotten countries, drawn on the reliefs that outlived them."
#
# The geography of Carthage never changed — only the map did. So:
#   * the RELIEF is built from modern DEM data (real mountains, real coast),
#   * the BORDERS come from a historical world-borders atlas for a given year,
#   * everything outside the vanished realm is washed back to pale paper,
#     so the dead polity is the only thing in full hypsometric colour.
#
# Runs in four independent stages, each cached, so the expensive step
# (the DEM + the ray-traced render) is never repeated needlessly:
#
#   PART 1  geometry   — historic borders + coastline          (seconds)
#   PART 2  basemap    — DEM  -> dem_cache/<slug>_z<z>.tif     (minutes, cached)
#   PART 3  render     — texture + overlays + render_highquality (slow)
#   PART 4  furnish    — magick chrome, reads the PNG off disk  (seconds)
#
# BASEMAP_ONLY = TRUE renders the underlying relief with NO borders at all
# (a reusable plate: <slug>_basemap.png), which is what you want if you plan
# to draw the borders by hand / in another tool later.
#
# Data: aourednik/historical-basemaps (borders, 3000 BC -> 2010)
#       Pleiades (ancient settlements)  |  Natural Earth (coastline, lakes)
# ============================================================

if (!require("pacman")) install.packages("pacman")
pacman::p_load(terra, elevatr, sf, tidyverse, rayshader, magick, jsonlite)

sf::sf_use_s2(FALSE)
options(timeout = 1200)

# ============================================================
# PART 0 — THE REGISTRY OF FORGOTTEN REALMS
# ============================================================
# `year`  : which historical-basemaps sheet to open (see YEARS below)
# `match` : regex against the NAME field (ASCII-safe prefixes survive the
#           encoding mess in the source data — use list_realms() to browse)
# `title` : what gets letterpressed on the plate
# `crs`   : NULL = auto Albers Equal-Area fitted to the realm
# `exag`  : VERTICAL EXAGGERATION, not zscale. A realm can be 300 km or 3000 km
#           wide, so the pixel is never the same size twice — hardcoding zscale
#           is what turns a relief into black mud. zscale = pixel_metres / exag.
#           It is not fully scale-free either: a coarse grid has averaged its own
#           slopes away, so a 3000 km realm takes exag 45-55 while a 300 km one
#           wants 25-30 for the same 1906 lightness. Too dark = lower exag.

REALMS <- list(
  carthage = list(
    year = "bc200", match = "^Carthage", slug = "carthage",
    house = "COMMISSIO REI GEOLOGICAE", title = "CARTHAGO",
    subtitle = "IMPERIVM CARTHAGINIENSE  .  ANTE CHR. N. CC",
    sheet = "MMXXVI", exag = 25, margin_frac = 0.10, cities = "pleiades",
    gazetteer = "PUNIC_GAZETTEER", period = "hellenistic-republican"
  ),
  carthaginian_empire = list(
    year = "bc300", match = "^Carthaginian", slug = "carthago_magna",
    house = "COMMISSIO REI GEOLOGICAE", title = "CARTHAGO",
    subtitle = "IMPERIVM CARTHAGINIENSE  .  ANTE CHR. N. CCC",
    sheet = "MMXXVI", exag = 45, margin_frac = 0.10, cities = "pleiades",
    gazetteer = "PUNIC_GAZETTEER", period = "classical"
  ),
  numidia = list(
    year = "bc200", match = "^Kingdom of Gala|^Kingdom of Syphax", slug = "numidia",
    house = "COMMISSIO REI GEOLOGICAE", title = "NVMIDIA",
    subtitle = "REGNA MASINISSAE ET SYPHACIS  .  ANTE CHR. N. CC",
    sheet = "MMXXVI", exag = 28, margin_frac = 0.12, cities = "pleiades",
    gazetteer = "PUNIC_GAZETTEER", period = "hellenistic-republican"
  ),
  aragon = list(
    year = "1300", match = "^Arag", slug = "aragon",
    house = "COMISSIO DEL SERVEI GEOLOGIC", title = "ARAGO",
    subtitle = "CORONA D'ARAGO  .  ANY MCCC",
    sheet = "MMXXVI", exag = 55, margin_frac = 0.15, cities = "none", period = NA
  ),
  old_prussia = list(
    year = "1000", match = "^Prussians", slug = "prussia_vetus",
    house = "GEOLOGISCHE LANDESAUFNAHME", title = "PRUSSIA",
    subtitle = "TERRA PRUSSORUM  .  ANNO MM",
    sheet = "MMXXVI", exag = 75, margin_frac = 0.25, cities = "none", period = NA
  ),
  two_sicilies = list(
    year = "1815", match = "^Kingdom of the Two Sicilies", slug = "due_sicilie",
    house = "R. COMMISSIONE GEOLOGICA", title = "DUE SICILIE",
    subtitle = "REGNO DELLE DUE SICILIE  .  ANNO MDCCCXV",
    sheet = "MMXXVI", exag = 55, margin_frac = 0.12, cities = "none", period = NA
  ),
  yugoslavia = list(
    year = "1938", match = "^Yugoslavia", slug = "yugoslavia",
    house = "GEOLOSKI ZAVOD", title = "JUGOSLAVIJA",
    subtitle = "KRALJEVINA JUGOSLAVIJA  .  GODINE MCMXXXVIII",
    sheet = "MMXXVI", exag = 50, margin_frac = 0.12, cities = "none", period = NA
  )
)
# ---- THE GAZETTEER ------------------------------------------
# Hand-checked against the Pleiades dump. This table exists because Pleiades
# cannot pick its own headline acts: `title` stacks name variants behind
# slashes, so a naive str_replace("/.*$") prints "Gadeira" for Gades, "Sexi"
# for a village, "Ilici" where CARTHAGO NOVA belongs — and Carthage itself falls
# outside its own (very coarse) border polygon and is dropped altogether.
# `tier`: 1 = the capital, 2 = the great cities, 3 = the rest of the network.
# Coordinates are the Pleiades representative points, so duplicate titles
# (three Tipasas, three Olbias, two Sulcis) are already disambiguated.
PUNIC_GAZETTEER <- tibble::tribble(
  ~label,             ~tier, ~lat,    ~lon,
  "CARTHAGO",             1L, 36.853,  10.323,
  "UTICA",                2L, 37.056,  10.060,
  "HADRUMETUM",           2L, 35.826,  10.639,
  "HIPPO REGIUS",         2L, 36.883,   7.750,
  "HIPPO DIARRHYTUS",     2L, 37.276,   9.873,
  "CIRTA",                2L, 36.368,   6.613,
  "LEPCIS MAGNA",         2L, 32.636,  14.297,
  "SABRATHA",             2L, 32.805,  12.485,
  "OEA",                  2L, 32.898,  13.175,
  "IOL",                  2L, 36.607,   2.192,
  "TINGI",                2L, 35.788,  -5.810,
  "GADES",                2L, 36.529,  -6.293,
  "CARTHAGO NOVA",        2L, 37.603,  -0.988,
  "MALACA",               2L, 36.720,  -4.420,
  "SAGVNTVM",             2L, 39.678,  -0.277,
  "EBVSVS",               2L, 38.908,   1.432,
  "PANORMVS",             2L, 38.111,  13.352,
  "LILYBAEVM",            2L, 37.803,  12.430,
  "MOTYA",                2L, 37.867,  12.468,
  "CARALIS",              2L, 39.215,   9.110,
  "THARROS",              2L, 39.875,   8.441,
  "THAPSVS",              3L, 35.621,  11.043,
  "LEPTIS MINOR",         3L, 35.678,  10.866,
  "THYSDRVS",             3L, 35.296,  10.708,
  "TACAPE",               3L, 33.886,  10.109,
  "GIGTHIS",              3L, 33.532,  10.677,
  "NEPHERIS",             3L, 36.615,  10.383,
  "ZAMA REGIA",           3L, 36.112,   9.286,
  "THVGGA",               3L, 36.423,   9.219,
  "SICCA VENERIA",        3L, 36.181,   8.712,
  "ICOSIVM",              3L, 36.769,   3.053,
  "TIPASA",               3L, 36.594,   2.442,
  "CARTENNA",             3L, 36.510,   1.311,
  "SALDAE",               3L, 36.741,   5.058,
  "SIGA",                 3L, 35.253,  -1.452,
  "RVSADDIR",             3L, 35.292,  -2.939,
  "LIXVS",                3L, 35.200,  -6.110,
  "SEXI",                 3L, 36.735,  -3.691,
  "ABDERA",               3L, 36.748,  -3.023,
  "BARIA",                3L, 37.245,  -1.775,
  "DREPANVM",             3L, 38.017,  12.518,
  "SOLVNTVM",             3L, 38.092,  13.531,
  "SELINVS",              3L, 37.586,  12.829,
  "NORA",                 3L, 38.984,   9.016,
  "SVLCI",                3L, 39.071,   8.451,
  "OLBIA",                3L, 40.923,   9.500,
  "TVRRIS LIBISONIS",     3L, 40.837,   8.396
)


# ---- PICK YOUR DEAD COUNTRY ---------------------------------
REALM_KEY    <- "carthaginian_empire"
BASEMAP_ONLY <- FALSE     # TRUE = pure relief plate, no borders, no labels
TARGET_MAX   <- 1400      # shading-matrix long side (1000-1500 is the budget)
RENDER_MAX   <- 2000      # long side of the rendered PNG
SAMPLES      <- 256
Z_LEVEL      <- NA        # NA = auto-fit elevatr zoom to TARGET_MAX
N_CITIES     <- 26        # ceiling; de-crowding usually keeps fewer

# The realm is the ONLY thing in relief. Everything else — neighbouring land,
# the sea — is a flat old paper map carrying names, coastlines and rivers, so
# the dead country rises off the sheet on its own. Because the relief edge IS
# the frontier (it throws a real contact shadow onto the paper), the drawn
# political border is redundant: off by default.
SHOW_BORDER     <- FALSE  # TRUE = also engrave the frontier as an ink line
SHOW_NEIGHBOURS <- TRUE   # letterpress names of the other polities of that year
SHOW_RIVERS     <- TRUE   # HydroRIVERS, full frame (faint on the paper)
SHOW_COAST      <- TRUE   # engrave every coastline, realm and paper alike

R <- REALMS[[REALM_KEY]]
stopifnot(!is.null(R))

# ---- the house palette: desert hypsometry, straight off the 1906 plate ----
# cream flats -> sand -> ochre -> burnt orange -> umber peaks. No green.
HYPSO_STOPS <- c("#F5F1E6", "#F0E7D3", "#E9DCBC", "#E0CDA2",
                 "#D6BA85", "#CBA463", "#BE8B40", "#AC7124",
                 "#925612", "#75400A")
HYPSO_POS   <- c(0, .05, .11, .19, .29, .42, .57, .73, .88, 1)^0.90
PAPER       <- "#F4F1E7"
SEA_SHELF   <- "#CFE2DA"
SEA_DEEP    <- "#AFCFC9"
INK         <- "#5E5140"
INK_SOFT    <- "#9C907C"
SEPIA       <- "#4A3B28"
RIVER       <- "#4E8B80"
LAKE        <- "#77A9A0"

hypso_ramp <- function(n = 512) {
  grDevices::colorRamp(HYPSO_STOPS)(HYPSO_POS) |>
    rgb(maxColorValue = 255) |> colorRampPalette() |> (\(f) f(n))()
}

BASE_PNG  <- sprintf("%s_basemap.png", R$slug)
RELIEF_PNG <- sprintf("%s_relief.png", R$slug)
FINAL_PNG  <- sprintf("%s_carta_final.png", R$slug)
OUT_PNG    <- if (BASEMAP_ONLY) BASE_PNG else RELIEF_PNG

hdri_url  <- "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/photo_studio_loft_hall_4k.hdr"
hdri_file <- basename(hdri_url)
if (!file.exists(hdri_file)) download.file(hdri_url, hdri_file, mode = "wb")

# ============================================================
# PART 1 — GEOMETRY: borders that no longer exist
# ============================================================
HB_DIR <- "histbasemaps"
HB_URL <- "https://raw.githubusercontent.com/aourednik/historical-basemaps/master/geojson"
dir.create(HB_DIR, showWarnings = FALSE)

hb_sheet <- function(year) {
  f <- file.path(HB_DIR, sprintf("world_%s.geojson", year))
  if (!file.exists(f)) download.file(sprintf("%s/world_%s.geojson", HB_URL, year), f, mode = "wb")
  st_read(f, quiet = TRUE) |> st_make_valid() |>
    mutate(NAME = enc2utf8(as.character(NAME))) |>
    filter(!is.na(NAME))
}

# browse any sheet:  list_realms("bc200")
list_realms <- function(year) sort(unique(hb_sheet(year)$NAME))

world <- hb_sheet(R$year)
realm <- world |> filter(str_detect(NAME, R$match))
if (nrow(realm) == 0) stop("no NAME matched '", R$match, "' in sheet ", R$year,
                           " — try list_realms('", R$year, "')")
cat("realm:", paste(unique(realm$NAME), collapse = " + "), "\n")
realm <- st_union(st_make_valid(realm)) |> st_as_sf() |> st_make_valid()

# ---- projection: Albers Equal-Area fitted to the realm ------
bb <- st_bbox(realm)
CRS_PROJ <- if (!is.null(R$crs)) R$crs else sprintf(
  "+proj=aea +lat_1=%.3f +lat_2=%.3f +lat_0=%.3f +lon_0=%.3f +datum=WGS84 +units=m +no_defs",
  bb["ymin"] + (bb["ymax"] - bb["ymin"]) / 6,
  bb["ymax"] - (bb["ymax"] - bb["ymin"]) / 6,
  (bb["ymin"] + bb["ymax"]) / 2, (bb["xmin"] + bb["xmax"]) / 2)
cat("crs:", CRS_PROJ, "\n")

realm_p <- st_transform(realm, CRS_PROJ)
rb      <- st_bbox(realm_p)
pad     <- R$margin_frac * max(rb["xmax"] - rb["xmin"], rb["ymax"] - rb["ymin"])
frame_bbox <- rb + c(-pad, -pad, pad, pad)
frame_sf   <- st_as_sfc(frame_bbox) |> st_set_crs(CRS_PROJ)
frame_ll   <- st_transform(frame_sf, 4326)
fl         <- st_bbox(frame_ll)

# ---- coastline (Natural Earth land) ------------------------
if (!file.exists("ne_land/ne_10m_land.shp")) {
  lu <- "https://naciscdn.org/naturalearth/10m/physical/ne_10m_land.zip"
  download.file(lu, basename(lu), mode = "wb"); unzip(basename(lu), exdir = "ne_land")
}
land <- st_read("ne_land/ne_10m_land.shp", quiet = TRUE) |> st_make_valid() |>
  st_crop(fl) |> st_transform(CRS_PROJ)

if (!file.exists("ne_lakes/ne_10m_lakes.shp")) {
  lu <- "https://naciscdn.org/naturalearth/10m/physical/ne_10m_lakes.zip"
  download.file(lu, basename(lu), mode = "wb"); unzip(basename(lu), exdir = "ne_lakes")
}
lakes <- st_read("ne_lakes/ne_10m_lakes.shp", quiet = TRUE) |> st_make_valid() |>
  st_crop(fl) |> st_transform(CRS_PROJ)

# ---- the other polities of that year (context) --------------
neigh <- world |> filter(!str_detect(NAME, R$match)) |> st_make_valid() |>
  st_crop(fl) |> st_transform(CRS_PROJ)
neigh <- neigh[as.numeric(st_area(neigh)) > 0, ]
# ---- rivers (HydroRIVERS) -----------------------------------
# Natural Earth's 10m rivers are a wall map generalisation: 24 lines in the
# whole Carthage frame, which is not a drainage network, it is a decoration.
# HydroRIVERS is the real thing, but it is the OPPOSITE problem — 62,000 reaches
# in the same frame, every Saharan wadi included, which paints the Atlas solid
# green. So we cut on DISCHARGE, not on stream order: a river a Punic captain
# could have sailed carries water, a wadi carries none, and the desert empties
# itself off the plate exactly as it should. Then we cap the count so the pen
# density is the same whether the realm is 300 km or 3000 km wide.
# The shapefiles are ~150 MB, so we never read them whole — wkt_filter pushes
# the frame down into the OGR driver.
HR_URL <- "https://data.hydrosheds.org/file/HydroRIVERS/HydroRIVERS_v10_%s_shp.zip"
RIVER_MIN_CMS <- 1        # m3/s: a real stream. A wadi is 0, so the desert clears
RIVER_MAX <- 1600         # reaches actually drawn, strongest-flowing first
hydro_region <- function(bb) {           # which continental pack(s) the frame needs
  r <- character(0)
  if (bb["ymin"] < 36 && bb["xmin"] < 52)                       r <- c(r, "af")
  if (bb["ymax"] > 33 && bb["xmax"] > -25 && bb["xmin"] < 70)   r <- c(r, "eu")
  if (length(r) == 0) r <- "eu"
  r
}
load_rivers <- function(bb) {
  wkt <- st_as_text(st_as_sfc(st_bbox(c(xmin = bb[["xmin"]], ymin = bb[["ymin"]],
                                       xmax = bb[["xmax"]], ymax = bb[["ymax"]]),
                                     crs = 4326)))
  out <- list()
  for (rg in hydro_region(bb)) {
    shp <- sprintf("HydroRIVERS_v10_%s_shp/HydroRIVERS_v10_%s.shp", rg, rg)
    if (!file.exists(shp)) shp <- sprintf("HydroRIVERS_v10_%s.shp", rg)
    if (!file.exists(shp)) {
      z <- sprintf("HydroRIVERS_v10_%s_shp.zip", rg)
      if (!file.exists(z)) try(download.file(sprintf(HR_URL, rg), z, mode = "wb"), silent = TRUE)
      if (file.exists(z)) try(unzip(z, exdir = "."), silent = TRUE)
      shp <- sprintf("HydroRIVERS_v10_%s_shp/HydroRIVERS_v10_%s.shp", rg, rg)
    }
    if (!file.exists(shp)) { message("rivers: no ", rg, " pack, skipping"); next }
    x <- try(st_read(shp, wkt_filter = wkt, quiet = TRUE), silent = TRUE)
    if (!inherits(x, "try-error") && nrow(x) > 0) out[[rg]] <- x[c("ORD_FLOW", "DIS_AV_CMS")]
  }
  if (length(out) == 0) return(NULL)
  r <- do.call(rbind, out) |> st_transform(CRS_PROJ) |>
    filter(!is.na(DIS_AV_CMS), DIS_AV_CMS >= RIVER_MIN_CMS) |>
    arrange(desc(DIS_AV_CMS))
  if (nrow(r) > RIVER_MAX) r <- r[seq_len(RIVER_MAX), ]
  r |> mutate(w = c(3.0, 3.0, 2.6, 2.1, 1.6, 1.2, 0.9, 0.7, 0.55)[pmin(pmax(ORD_FLOW, 1), 9)])
}
rivers <- if (SHOW_RIVERS) load_rivers(fl) else NULL
cat("rivers:", if (is.null(rivers)) 0 else nrow(rivers), "reaches\n")



# ============================================================
# PART 2 — THE BASEMAP: a DEM of the ground, cached to disk
# This is the "underlying map", generated (and reusable) on its own.
# ============================================================
dir.create("dem_cache", showWarnings = FALSE)

span_deg <- max(fl["xmax"] - fl["xmin"], fl["ymax"] - fl["ymin"])
ZL <- if (is.na(Z_LEVEL)) {
  max(3, min(10, round(log2(2 * TARGET_MAX * 360 / (256 * span_deg)))))
} else Z_LEVEL
cat("frame span:", round(span_deg, 2), "deg   elevatr zoom:", ZL, "\n")

dem_tif <- sprintf("dem_cache/%s_z%d_t%d.tif", R$slug, ZL, TARGET_MAX)
if (file.exists(dem_tif)) {
  dem_s <- terra::rast(dem_tif)
  cat("DEM from cache:", dem_tif, "\n")
} else {
  dem_raw <- elevatr::get_elev_raster(st_as_sf(frame_ll), z = ZL, clip = "bbox") |>
    terra::rast() |> terra::project(CRS_PROJ) |> terra::crop(terra::vect(frame_sf))
  res_t <- mean(terra::res(dem_raw))                    # force square pixels
  dem <- terra::resample(dem_raw, terra::rast(extent = terra::ext(dem_raw),
                                              crs = CRS_PROJ, resolution = res_t))
  agg <- max(1, round(max(dim(dem)[1:2]) / TARGET_MAX)) # mean-aggregate, never resize_matrix
  dem_s <- if (agg > 1) terra::aggregate(dem, fact = agg, fun = "mean", na.rm = TRUE) else dem
  terra::writeRaster(dem_s, dem_tif, overwrite = TRUE)
  cat("DEM written:", dem_tif, "  agg =", agg, "\n")
}
names(dem_s) <- "elev"
cat("shading matrix:", dim(dem_s)[1:2], "\n")

# zscale from the ACTUAL pixel size, so `exag` means the same thing on a
# 300 km realm and a 3000 km one (this is the difference between a relief
# and a field of black spikes)
PIX <- mean(terra::res(dem_s))
ZS  <- max(0.5, PIX / R$exag)
cat("pixel:", round(PIX), "m   exaggeration:", R$exag, "x   zscale:", round(ZS, 1), "\n")

# ---- masks, rasterized straight onto the shading grid -------
land_r  <- terra::rasterize(terra::vect(land),    dem_s, field = 1, background = NA)
realm_r <- terra::rasterize(terra::vect(realm_p), dem_s, field = 1, background = NA)

elev  <- terra::classify(dem_s, cbind(-Inf, 0, 0))      # land bathymetry -> 0
elev[is.na(land_r)] <- 0                                # sea is a flat plate
elev[is.na(elev)]   <- 0                                # reprojection slivers
# THE RELIEF STOPS AT THE FRONTIER. Outside the realm the ground is planed down
# to the sheet, so the dead country is a plateau standing on a flat paper map
# and its own edge throws the contact shadow that a drawn border used to.
# (BASEMAP_ONLY keeps the whole DEM — that plate is the ground, not the story.)
if (!BASEMAP_ONLY) elev[is.na(realm_r)] <- 0
m       <- rayshader::raster_to_matrix(elev)
# NOTE: height_shade() returns dim = rev(dim(heightmap)) — the rgb array is the
# TRANSPOSE of the matrix. Anything used as a pixel mask on that array must be
# transposed too, or you get diagonal striping instead of a coastline.
depth    <- t(rayshader::raster_to_matrix(dem_s))
is_land  <- t(!is.na(rayshader::raster_to_matrix(land_r)))
in_realm <- t(!is.na(rayshader::raster_to_matrix(realm_r)))
is_sea   <- !is_land

# stretch the hypsometry over the REALM's own relief, not over the whole frame.
# Otherwise a single Alpine neighbour compresses the dead country into the cream
# end of the ramp and the plate comes out grey. 98.5th percentile, so one summit
# cannot set the scale for a whole province.
rvals <- terra::values(dem_s)[!is.na(terra::values(realm_r))]
rvals <- rvals[is.finite(rvals) & rvals > 0]
ELEV_TOP <- if (length(rvals) > 50) as.numeric(quantile(rvals, 0.985)) else max(m, 1)
cat("hypsometric ceiling:", round(ELEV_TOP), "m\n")

# ============================================================
# PART 3 — TEXTURE, OVERLAYS, RENDER
# ============================================================
# paint a colour onto an rgb array through a logical mask
paint <- function(arr, mask, col, alpha = 1) {
  v <- as.numeric(grDevices::col2rgb(col)) / 255
  idx <- which(mask)
  for (k in 1:3) {
    ch <- arr[, , k]
    ch[idx] <- (1 - alpha) * ch[idx] + alpha * v[k]
    arr[, , k] <- ch
  }
  arr
}
# letterpress place names straight onto the relief, georeferenced.
# (rayshader's own generate_label_overlay() needs {car} for its collision
#  solver and silently no-ops without it — this does the same job with base
#  graphics only, using rayshader's exact device convention so it aligns.)
letterpress_overlay <- function(pts, extent, heightmap, label_column,
                                text_size = 1.3, color = "#3E3120",
                                halo_color = PAPER, halo_expand = 2.5,
                                font = 2, pos = 3) {
  e <- rayshader:::get_extent(extent)
  wpx <- nrow(heightmap); hpx <- ncol(heightmap)
  xy <- sf::st_coordinates(sf::st_geometry(pts))
  lab <- as.character(pts[[label_column]])
  tf <- tempfile(fileext = ".png")
  grDevices::png(tf, width = wpx, height = hpx, units = "px", bg = "transparent")
  graphics::par(mar = c(0, 0, 0, 0))
  graphics::plot(sf::st_geometry(pts), xlim = c(e["xmin"], e["xmax"]),
                 ylim = c(e["ymin"], e["ymax"]), asp = 1, xaxs = "i", yaxs = "i",
                 pch = NA, col = NA)
  d <- halo_expand * (e["xmax"] - e["xmin"]) / wpx
  if (!is.na(halo_color) && halo_expand > 0) {
    for (a in seq(0, 2 * pi, length.out = 13)[-13]) {
      graphics::text(xy[, 1] + d * cos(a), xy[, 2] + d * sin(a), lab,
                     cex = text_size, col = halo_color, font = font, pos = pos)
    }
  }
  graphics::text(xy[, 1], xy[, 2], lab, cex = text_size, col = color,
                 font = font, pos = pos)
  grDevices::dev.off()
  rayimage::ray_read_image(tf)
}


tex <- rayshader::height_shade(m, texture = hypso_ramp(512), range = c(0, ELEV_TOP))

# relief shading — keep it LIGHT. The 1906 plate is a colour-printed hypsometry
# with a hint of hill-shading on top, not a grey hillshade tinted brown: push
# max_darken past ~0.3 and the whole desert ramp goes to ash.
ray <- rayshader::ray_shade(m, zscale = ZS, sunaltitude = 55,
                            sunangle = 315, multicore = TRUE)
amb <- rayshader::ambient_shade(m, zscale = ZS, maxsearch = 20, multicore = TRUE)

shaded <- tex |>
  add_shadow(ray, max_darken = 0.34) |>
  add_shadow(amb, max_darken = 0.14)

# THE COMPOSITION RULE: the forgotten realm is the only ground with a surface.
# Everything around it is a flat old paper map — no hypsometry, no hillshade,
# just the sheet with its coastlines, rivers and names printed on it. `m` has
# already been flattened outside the realm (PART 2), so the mesh is a plateau
# standing on a table; here we strip the leftover shading off the tabletop.
if (!BASEMAP_ONLY) shaded <- paint(shaded, is_land & !in_realm, PAPER, 1)

# the sea, repainted flat AFTER shading so no cliff shadows bleed into it
shaded <- paint(shaded, is_sea, SEA_DEEP, 1)
shaded <- paint(shaded, is_sea & depth > -220, SEA_SHELF, 1)

# ---- vector overlays ----------------------------------------
ov <- function(base, layer, alpha) tryCatch(add_overlay(base, layer, alphalayer = alpha),
                                            error = function(e) { message("overlay skipped: ",
                                            conditionMessage(e)); base })
if (nrow(lakes) > 0) {
  shaded <- ov(shaded, generate_polygon_overlay(lakes, extent = dem_s, heightmap = m,
                                                palette = LAKE, linewidth = 0), 0.9)
}

# rivers, drawn full-frame: strong inside the realm, faint on the paper, so the
# flat surround still reads as a map and not as a blank mount
if (SHOW_RIVERS && !is.null(rivers) && nrow(rivers) > 0) {
  r_in  <- suppressWarnings(st_intersection(rivers, realm_p))
  r_out <- suppressWarnings(st_difference(rivers, realm_p))
  for (ly in list(list(r_out, 0.62, 0.75), list(r_in, 1.0, 1.0))) {
    g <- ly[[1]]
    if (nrow(g) == 0) next
    shaded <- ov(shaded, generate_line_overlay(st_cast(g, "MULTILINESTRING"),
                                               extent = dem_s, heightmap = m,
                                               color = RIVER,
                                               linewidth = g$w * ly[[3]]), ly[[2]])
  }
}

# every coastline engraved, realm and paper alike — the cream end of the
# hypsometry sits at paper value, so without a drawn shore the coast dissolves
if (SHOW_COAST && nrow(land) > 0) {
  cl <- st_cast(st_boundary(land), "MULTILINESTRING")
  shaded <- ov(shaded, generate_line_overlay(cl, extent = dem_s, heightmap = m,
                                             color = INK_SOFT, linewidth = 1.8), 0.75)
  shaded <- ov(shaded, generate_line_overlay(cl, extent = dem_s, heightmap = m,
                                             color = SEPIA, linewidth = 0.9), 0.9)
}

if (!BASEMAP_ONLY) {
  if (SHOW_NEIGHBOURS && nrow(neigh) > 0) {
    shaded <- ov(shaded, generate_line_overlay(st_cast(st_boundary(neigh), "MULTILINESTRING"),
                                               extent = dem_s, heightmap = m,
                                               color = INK_SOFT, linewidth = 1.6), 0.45)
  }
  # the frontier is the edge of the relief itself, casting its own contact
  # shadow onto the paper, so the drawn line is normally redundant
  if (SHOW_BORDER) {
    bl <- st_cast(st_boundary(realm_p), "MULTILINESTRING")
    shaded <- ov(shaded, generate_line_overlay(bl, extent = dem_s, heightmap = m,
                                               color = PAPER, linewidth = 9), 0.45)
    shaded <- ov(shaded, generate_line_overlay(bl, extent = dem_s, heightmap = m,
                                               color = INK, linewidth = 3.2), 0.95)
  }
}

# ---- ancient settlements ------------------------------------
# Two routes. If the realm carries a curated gazetteer we use it, because
# Pleiades cannot be trusted to pick its own headline acts: its `title` field
# stacks name variants behind slashes ("Gadeira/Gades/Col. Augusta Gaditana",
# "Carthago Nova/Col. Urbs Iulia"), so cutting at the first slash hands you
# "Gadeira" and "Sexi" while CARTHAGE ITSELF never appears — the bc300 border
# polygon is coarse enough to exclude its own capital. A hand-checked table of
# titles, coordinates and ranks is the only way to letterpress the right words.
cities <- NULL
GZ <- if (!is.null(R$gazetteer)) get(R$gazetteer) else NULL

if (!BASEMAP_ONLY && !is.null(GZ)) {
  g <- GZ |>
    filter(lon > fl["xmin"], lon < fl["xmax"], lat > fl["ymin"], lat < fl["ymax"]) |>
    arrange(tier)
  cities <- st_as_sf(g, coords = c("lon", "lat"), crs = 4326) |> st_transform(CRS_PROJ)
} else if (!BASEMAP_ONLY && identical(R$cities, "pleiades")) {
  pf <- "pleiades-places-latest.csv.gz"
  if (!file.exists(pf)) {
    download.file("https://atlantides.org/downloads/pleiades/dumps/pleiades-places-latest.csv.gz",
                  pf, mode = "wb")
  }
  pl <- readr::read_csv(pf, show_col_types = FALSE, progress = FALSE) |>
    filter(!is.na(reprLat), !is.na(reprLong),
           locationPrecision == "precise",
           str_detect(featureTypes, "settlement"),
           reprLong > fl["xmin"], reprLong < fl["xmax"],
           reprLat  > fl["ymin"], reprLat  < fl["ymax"])
  if (!is.na(R$period)) pl <- pl |> filter(str_detect(timePeriodsKeys, R$period))
  # antiquity has no census: rank a place by how many eras it survived, and give
  # ports a bonus — a Punic city that mattered was a city you could sail to
  pl <- pl |>
    mutate(score = str_count(timePeriodsKeys, ",") + 1 +
                   2 * str_detect(featureTypes, "port"),
           label = title |> str_replace_all("\\s*\\(.*?\\)", "") |>
                            str_replace("/.*$", "") |> str_squish(),
           tier = 2L) |>
    filter(!str_detect(label, "^\\(|\\?|[0-9]"),
           !str_detect(str_to_lower(label),
                       "complex|nuragh|nuraghe|tomb|villa|necropol|site|unnamed"),
           str_length(label) > 2, str_length(label) < 18) |>
    arrange(desc(score), label)
  cities <- st_as_sf(pl, coords = c("reprLong", "reprLat"), crs = 4326) |>
    st_transform(CRS_PROJ)
}

if (!is.null(cities) && nrow(cities) > 0) {
  # de-crowd on the SHAPE OF THE WORD, not on a circle. A name is wide and
  # short, so a radius big enough to stop "HIPPO REGIUS" running into
  # "CARTHAGO" also throws away every city stacked vertically above them: the
  # first version of this kept 11 places on a plate that has room for 20.
  # So: walk down the ranking and keep a place only if its type box clears the
  # boxes already set. Width is per-character and per-rank, because the capital
  # is set in large caps and a minor port in small type.
  fw <- as.numeric(frame_bbox["xmax"] - frame_bbox["xmin"])
  fh <- as.numeric(frame_bbox["ymax"] - frame_bbox["ymin"])
  tt <- pmin(cities$tier, 3)
  hw <- str_length(cities$label) * c(.0115, .0092, .0070)[tt] * fw / 2
  hh <- c(.024, .020, .016)[tt] * fh / 2
  xy <- st_coordinates(cities); keep <- integer(0)
  for (i in seq_len(nrow(cities))) {
    clash <- length(keep) > 0 &&
      any(abs(xy[keep, 1] - xy[i, 1]) < (hw[keep] + hw[i]) &
          abs(xy[keep, 2] - xy[i, 2]) < (hh[keep] + hh[i]))
    if (!clash) keep <- c(keep, i)
    if (length(keep) >= N_CITIES) break
  }
  cities <- cities[keep, ]
  cat("settlements:", nrow(cities), "->", paste(cities$label, collapse = ", "), "\n")
}

# every overlay is drawn on a device the size of the shading matrix, so cex and
# pch sizes are in matrix pixels, not in map units: a type size that reads at
# 1400 is a set of blobs at 700. Tie it to the matrix and the plate looks the
# same at draft resolution as at full.
TSCALE <- max(dim(m)) / 1400

if (!is.null(cities) && nrow(cities) > 0) {
  # rank sets the weight of the type, the way a real gazetteer plate does:
  # the capital in large caps, the great cities next, the rest in small type
  for (tr in sort(unique(cities$tier))) {
    ct <- cities[cities$tier == tr, ]
    cx  <- c(1.95, 1.55, 1.15)[min(tr, 3)] * TSCALE
    dot <- c(2.4, 1.7, 1.1)[min(tr, 3)] * TSCALE
    shaded <- ov(shaded, generate_point_overlay(ct, extent = dem_s, heightmap = m,
                                                color = SEPIA, size = dot, pch = 19), 0.95)
    shaded <- ov(shaded, letterpress_overlay(ct, extent = dem_s, heightmap = m,
                                             label_column = "label", text_size = cx,
                                             color = SEPIA, halo_color = PAPER,
                                             halo_expand = 2.5,
                                             font = if (tr == 1) 2 else 1), 1)
  }
}

# ---- the names of the vanished neighbours, letterpressed in place ----
# labelled on the part of each polity that is actually ON the sheet, inset from
# the edge, so nothing gets guillotined by the frame
if (!BASEMAP_ONLY && SHOW_NEIGHBOURS && nrow(neigh) > 0) {
  inset <- st_as_sfc(frame_bbox - 0.07 * c(-1, -1, 1, 1) *
                       (frame_bbox["xmax"] - frame_bbox["xmin"])) |> st_set_crs(CRS_PROJ)
  nl <- suppressWarnings(st_intersection(neigh, inset)) |> st_make_valid()
  nl <- nl[!st_is_empty(nl), ]
  if (nrow(nl) > 0) {
    nl <- nl |> mutate(a = as.numeric(st_area(nl))) |>
      filter(a > 0.015 * max(a)) |>
      st_point_on_surface() |>
      mutate(label = str_to_upper(str_replace_all(NAME, "-", " ")))
    shaded <- ov(shaded, letterpress_overlay(nl, extent = dem_s, heightmap = m,
                                             label_column = "label", text_size = 1.35 * TSCALE,
                                             color = INK_SOFT, halo_color = PAPER,
                                             halo_expand = 1.8, font = 1, pos = NULL), 0.8)
  }
}

rayshader::plot_map(shaded)     # 2D sanity peek before the slow render

asp <- as.numeric((frame_bbox["xmax"] - frame_bbox["xmin"]) /
                  (frame_bbox["ymax"] - frame_bbox["ymin"]))
if (asp >= 1) { rw <- RENDER_MAX; rh <- round(RENDER_MAX / asp)
} else        { rh <- RENDER_MAX; rw <- round(RENDER_MAX * asp) }

rayshader::plot_3d(shaded, m, zscale = ZS, solid = FALSE, shadow = FALSE,
                   background = PAPER, windowsize = c(round(rw / 2), round(rh / 2)),
                   zoom = 0.70, phi = 89, theta = 0)

rayshader::render_highquality(
  filename = OUT_PNG, preview = FALSE, light = FALSE,
  environment_light = hdri_file, intensity_env = 1.15,
  interactive = FALSE, width = rw, height = rh, samples = SAMPLES)

cat("render ->", OUT_PNG, "\n")

# ============================================================
# PART 4 — FURNISH THE PLATE (cheap; re-run alone to retune type)
# Reads the rendered PNG back off disk — no re-render needed.
# ============================================================
if (!BASEMAP_ONLY) {
stopifnot(file.exists(RELIEF_PNG))
# missing fonts? -> print(magick::magick_fonts(), n = 200)
raw <- image_read(RELIEF_PNG)
W <- image_info(raw)$width; H <- image_info(raw)$height
x <- function(f) round(W * f); y <- function(f) round(H * f)
FONT <- "Playfair Display"

plate <- raw |>
  image_annotate(R$house, font = FONT, size = y(0.019), gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.055)),
                 color = SEPIA, kerning = 6) |>
  image_annotate("CARTA HYPSOMETRICA", font = FONT, size = y(0.034),
                 gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.088)),
                 color = SEPIA, kerning = 10) |>
  image_annotate("D E", font = FONT, size = y(0.017), gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.135)), color = "#6B5B45") |>
  image_annotate(R$title, font = FONT, weight = 700, size = y(0.072),
                 gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.155)), color = "#3E3120",
                 kerning = 4) |>
  image_annotate(R$subtitle, size = y(0.015), gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.245)), color = "#6B5B45",
                 kerning = 3) |>
  image_annotate(R$sheet, font = FONT, size = y(0.021), gravity = "northwest",
                 location = paste0("+", x(0.05), "+", y(0.272)), color = SEPIA) |>
  image_annotate(sprintf("relief: SRTM/AWS z%d  |  fines: historical-basemaps %s", ZL, R$year),
                 size = y(0.011), gravity = "southeast",
                 location = paste0("+", x(0.04), "+", y(0.03)), color = "#8B7F6B")

# hypsometric legend swatch, drawn from the same ramp
ramp <- hypso_ramp(512)
sw <- image_graph(180, 320, res = 96); par(mar = c(0, 0, 0, 0))
image(1, seq_len(12), t(matrix(1:12)),
      col = rev(ramp[round(seq(1, 512, length.out = 12))]),
      axes = FALSE, xlab = "", ylab = ""); box(col = "#6B5B45"); dev.off()
plate <- image_composite(plate, sw, offset = paste0("+", x(0.06), "+", H - y(0.14))) |>
  image_annotate("LEGENDA", font = FONT, size = y(0.017), gravity = "southwest",
                 location = paste0("+", x(0.06), "+", y(0.155)),
                 color = SEPIA, kerning = 6)

image_write(image_border(plate, "#EDEAE2", "90x90"), FINAL_PNG, quality = 97)
cat("finished ->", FINAL_PNG, " (", W, "x", H, ")\n")
} else {
  cat("basemap only — chrome skipped. Plate:", BASE_PNG, "\n")
}

# ============================================================
# HOW TO ADD YOUR OWN DEAD COUNTRY
#   1. list_realms("bc500")            # see what existed that year
#   2. add an entry to REALMS with year + an ASCII-safe `match` regex
#   3. set REALM_KEY, run PART 1-3 once, then retune PART 4 for free
# Sheets available: bc123000 bc10000 bc8000 bc5000 bc4000 bc3000 bc2000 bc1500
#   bc1000 bc700 bc500 bc400 bc323 bc300 bc200 bc100 bc1 100 200 300 400 500
#   600 700 800 900 1000 1100 1200 1279 1300 1400 1492 1500 1530 1600 1650
#   1700 1715 1783 1800 1815 1880 1900 1914 1920 1930 1938 1945 1960 1994 2000 2010
# ============================================================