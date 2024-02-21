#! /usr/local/bin/Rscript
# install R dependencies

## Ensure spatial packages are installed from source
# We could use renv.lock approach here instead, but will force re-creation of environment from scratch
# Does not provide a good way to ensure that sf/terra/gdalcubes are installed from source while other packages can be binary
# Likewise, pak insists on installing old gdal from apt instead of respecting system library source builds
install.packages("pak")
pak::pkg_install(c("rstac", "spData", "earthdatalogin", "quarto", "aws.s3", "pak", "duckdbfs", "minioclient", "gifski"))
pak::pkg_install("r-tmap/tmap")

#remotes::install_github('r-tmap/tmap', upgrade="never", repos="https://cloud.r-project.org", dep=TRUE)


pak::pkg_install("igraph")
pak::pkg_install("ropensci-review-tools/pkgcheck")

# pak::pkg_install("httpgd")
pak::pkg_install(c("IRkernel", "languageserver"))
IRkernel::installspec()

