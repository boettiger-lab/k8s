install.packages(c('tidyverse', 'devtools', 'reticulate', 'nimble', 'duckdbfs', 'arrow', 'gdalcubes', 'rstac', 'terra', 'sf', 'stars', 'quarto', 'mapgl', 'neonstore', 'rfishbase', 'shiny', 'pak'))

readr::write_lines('
  options(repos = list(CRAN = sprintf(
    "https://r-lib.github.io/p/pak/stable/%s/%s/%s",
    .Platform$pkgType,
    R.Version()$os,
    R.Version()$arch
  )))', 
  paste0(R.home(), "/etc/Rprofile.site"),
  append = TRUE)


