# ============================================================
# Norway KPI mapping pipeline: FT/Economist-grade visuals
# Packages: sf, ggplot2, rayshader, geodata/rnaturalearth,
#           showtext, scales, dplyr
# ============================================================
# install.packages("Rcpp")
# library(Rcpp)
library(sf)
install.packages("sf")
# install.packages("tidyverse")
library(dplyr)
library(ggplot2)
library(scales)
library(showtext)

font_add_google("Archivo", "archivo")     # or your brand font
showtext_auto(); showtext_opts(dpi = 300)

# ---- 1. Geometry: Norwegian counties (GADM level 1) --------
# install.packages("geodata")
library(geodata)
nor <- gadm("NOR", level = 1, path = tempdir()) |> st_as_sf() |>
  st_transform(25833) |>                  # UTM33 – correct shape for Norway
  st_simplify(dTolerance = 500)           # crisp but light borders
nor$region <- nor$NAME_1

# ---- 2. Survey KPIs (replace with your weighted estimates) --
set.seed(1)
kpi <- tibble(
  region = nor$region,
  n      = sample(40:220, nrow(nor)),
  value  = round(runif(nrow(nor), 28, 62))
) |>
  mutate(
    national = weighted.mean(value, n),
    diff     = value - national,
    se       = sqrt(value/100 * (1 - value/100) / n) * 100,
    sig      = abs(diff) > 1.96 * se      # z-test vs national (approx.)
  )

map_df <- left_join(nor, kpi, by = "region")

# ---- 3. Theme -----------------------------------------------
theme_exec <- function() {
  theme_void(base_family = "archivo") +
  theme(
    plot.background  = element_rect(fill = "#12151a", colour = NA),
    plot.title    = element_text(colour = "#f2f2f2", size = 20, face = "bold",
                                 margin = margin(20, 0, 4, 20)),
    plot.subtitle = element_text(colour = "#9aa0a6", size = 12,
                                 margin = margin(0, 0, 10, 20)),
    plot.caption  = element_text(colour = "#6b7178", size = 9,
                                 margin = margin(10, 20, 15, 0)),
    legend.position = "none"
  )
}

# ---- 4. THE EXECUTIVE MAP (Concepts 1+4 combined) -----------
centroids <- st_point_on_surface(map_df)

p_exec <- ggplot(map_df) +
  geom_sf(aes(fill = diff), colour = "#12151a", linewidth = 0.4) +
  geom_sf(data = filter(map_df, sig),        # bright stroke = significant
          fill = NA, colour = "#ffd166", linewidth = 0.9) +
  geom_sf_text(data = centroids,
               aes(label = paste0(value, "%\n",
                                  ifelse(diff >= 0, "+", ""), round(diff))),
               family = "archivo", fontface = "bold",
               colour = "#f2f2f2", size = 3.2, lineheight = 0.9) +
  scale_fill_gradient2(low = "#e76f51", mid = "#3a4048", high = "#4d9de0",
                       midpoint = 0) +
  labs(
    title    = "Brand Consideration by Region",
    subtitle = sprintf("National average: %.0f%%  ·  yellow outline = significant at 95%%  ·  n = %d",
                       kpi$national[1], sum(kpi$n)),
    caption  = "Source: Brand Tracker Q2 2026 · weighted estimates"
  ) +
  theme_exec()

ggsave("exec_map.png", p_exec, width = 8, height = 10, dpi = 600,
       bg = "#12151a")                     # drops straight into PPT

# ---- 5. SMALL MULTIPLES (Concept 5) -------------------------
kpi_long <- tidyr::expand_grid(region = nor$region,
                               metric = c("Awareness","Consideration",
                                          "Usage","Recommendation")) |>
  mutate(value = round(runif(n(), 20, 80)))          # replace w/ real data

mm <- left_join(nor, kpi_long, by = "region") |>
  group_by(metric) |> mutate(diff = value - mean(value)) |> ungroup()

p_sm <- ggplot(mm) +
  geom_sf(aes(fill = diff), colour = "#12151a", linewidth = 0.25) +
  facet_wrap(~metric, nrow = 1) +
  scale_fill_gradient2(low = "#e76f51", mid = "#3a4048", high = "#4d9de0") +
  labs(title = "Funnel KPIs vs. national average") +
  theme_exec() +
  theme(strip.text = element_text(colour = "#f2f2f2", size = 12,
                                  face = "bold", margin = margin(6,0,6,0)))

ggsave("small_multiples.png", p_sm, width = 14, height = 6, dpi = 600,
       bg = "#12151a")

# ---- 6. RAYSHADER HERO (Concept 3) --------------------------
# ggplot -> plot_gg extrusion; height = KPI, colour = KPI
# install.packages("rayshader")
library(rayshader)

p_3d <- ggplot(map_df) +
  geom_sf(aes(fill = value), colour = NA) +
  scale_fill_gradient(low = "#1d3557", high = "#4d9de0") +
  theme_void() + theme(legend.position = "none",
                       plot.background = element_rect(fill = "#12151a",
                                                      colour = NA))

plot_gg(p_3d,
        multicore   = TRUE,
        width  = 6, height = 8, scale = 220,     # scale = extrusion strength
        shadow_intensity = 0.55,
        sunangle = 315,                          # soft NW light
        windowsize = c(1400, 1600),
        zoom = 0.55, phi = 32, theta = 12,
        background = "#12151a")

render_highquality("hero_3d.png",
                   samples = 360,
                   light = TRUE, lightdirection = 315,
                   lightaltitude = 45, lightintensity = 800,
                   width = 3000, height = 3600)   # ~500 DPI in a slide
