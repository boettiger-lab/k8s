## devcontainer-focused Rocker
FROM ghcr.io/rocker-org/devcontainer/tidyverse:4.3

## latest version of geospatial libs
RUN /rocker_scripts/experimental/install_dev_osgeo.sh
RUN apt-get update -qq && apt-get -y install vim

# podman doesn't not understand group permissions
RUN chown rstudio:staff -R ${R_HOME}/site-library

# some teaching preferences
RUN git config --system pull.rebase false && \
    git config --system credential.helper 'cache --timeout=36000'

## codeserver
RUN curl -fsSL https://code-server.dev/install.sh | sh

# Set up conda
ENV NB_USER=rstudio
ENV CONDA_ENV=/opt/miniforge3
ENV PATH=${CONDA_ENV}/bin:${PATH}
RUN curl -L -O "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh" && \
    bash Miniforge3-$(uname)-$(uname -m).sh -b -p ${CONDA_ENV} && \
    chown ${NB_USER}:staff -R ${CONDA_ENV}


# Initialize conda by default for all users:
RUN conda init --system

## Openscapes-specific configs
USER ${NB_USER} 
WORKDIR /home/${NB_USER}
RUN usermod -s /bin/bash ${NB_USER} 

# install into the default environment
COPY install.R install.R
RUN Rscript install.R && rm install.R

# consider installing jupyter-like stuff into base env instead?
# Create a conda-based env and install into it without using conda init/conda activate
# (this yaml file doesn't include everything from pangeo, consider a different one...)
ENV MY_ENV=${CONDA_ENV}/envs/openscapes
COPY environment.yml environment.yml
RUN conda env create -p ${MY_ENV} -f environment.yml

ENV PATH=${MY_ENV}/bin:${PATH}

