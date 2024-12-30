install.packages(c('tidyverse', 'devtools', 'reticulate', 'nimble', 'duckdbfs', 'arrow', 'gdalcubes', 'rstac', 'terra', 'sf', 'stars', 'quarto', 'mapgl', 'neonstore', 'rfishbase', 'shiny', 'pak'))

# NOTE: r-universe supports binaries only for latest R release and latest LTS, as follows:
readr::write_lines("
options(repos = c(
  linux = 'https://cran.r-universe.dev/bin/linux/noble/4.4/',
  sources = 'https://cran.r-universe.dev',
  cran = 'https://cloud.r-project.org'
))
", 
paste0(R.home(), "/etc/Rprofile.site"),
append = TRUE)


