FROM quay.io/jupyter/minimal-notebook

USER root

# Install R
COPY install_r.sh install_r.sh
RUN bash install_r.sh

# Now install any CRAN packages the usual way
RUN R -e "install.packages(c('terra', 'stars'))"

## Or the more concise Rocker way
RUN install2.r rstan ROracle

## RStudio
RUN conda install jupyter-rsession-proxy
COPY install_rstudio.sh install_rstudio.sh
RUN bash install_rstudio.sh

USER ${NB_USER}

