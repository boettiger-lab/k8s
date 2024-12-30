FROM quay.io/jupyter/minimal-notebook:ubuntu-24.04

# persistent storage (e.g. code-server extensions)
ENV XDG_DATA_HOME=/opt/share

COPY jupyter-ai.yml environment.yml
RUN conda update -n base -c conda-forge conda && \
    conda env update --file environment.yml

USER root

COPY install-utilities.sh install-utilities.sh
RUN bash install-utilities.sh && rm install-utilities.sh

# R & RStudio
RUN curl -s https://raw.githubusercontent.com/boettiger-lab/repo2docker-r/refs/heads/main/install_r.sh | bash
RUN curl -s https://raw.githubusercontent.com/boettiger-lab/repo2docker-r/refs/heads/main/install_rstudio.sh | bash

## Add rstudio's binaries to path for quarto
ENV PATH=$PATH:/usr/lib/rstudio-server/bin/quarto/bin

# When run as root, install.r automagically handles any necessary apt-gets
COPY install.r install.r
RUN Rscript install.r

## switch from BSPM to r-universe for user default 
COPY Rprofile /usr/lib/R/etc/Rprofile.site

USER ${NB_USER}



