FROM quay.io/jupyter/minimal-notebook:ubuntu-24.04

# Make code-server extensions etc persist to container, not hub
ENV XDG_DATA_HOME=/opt/share

# Python environment
COPY jupyter-ai.yml environment.yml
RUN conda update -n base -c conda-forge conda && \
    conda env update --file environment.yml

USER root

# code-server (VSCode)
RUN curl -fsSL https://code-server.dev/install.sh | sh && rm -rf .cache 

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
## switch from BSPM to r-universe for user default, only after BSPM does install.r! 
COPY Rprofile /usr/lib/R/etc/Rprofile.site

USER ${NB_USER}

RUN echo "ms-python.python ms-toolsai.jupyter quarto.quarto continue.continue ms-vscode.live-server posit.shiny reditorsupport.r alefragnani.project-manager" | xargs -n 1 code-server --install-extension

COPY spatial-env.yml spatial-env.yml
RUN conda update -n base -c conda-forge conda && \
    conda env update --file spatial-env.yml
# GDAL env var for vsi
ENV CPL_VSIL_USE_TEMP_FILE_FOR_RANDOM_WRITE=YES


