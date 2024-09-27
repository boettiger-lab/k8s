FROM quay.io/jupyter/pytorch-notebook:cuda12-ubuntu-24.04
COPY jupyter-ai.yml environment.yml

RUN conda update -n base -c conda-forge conda && \
    conda env update --file environment.yml

USER root
RUN curl -fsSL https://code-server.dev/install.sh | sh && rm -rf .cache
RUN git config --system pull.rebase false && \
    echo '"\e[5~": history-search-backward' >> /etc/inputrc && \
    echo '"\e[6~": history-search-forward' >> /etc/inputrc

RUN usermod -a -G staff ${NB_USER} \
  && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
  && locale-gen en_US.utf8 \
  && /usr/sbin/update-locale LANG=en_US.UTF-8

## Set some variables
ENV LC_ALL en_US.UTF-8
ENV LANG en_US.UTF-8
ENV DEBIAN_FRONTEND noninteractive
ENV TZ UTC

RUN curl -fsSL https://raw.githubusercontent.com/eddelbuettel/r2u/refs/heads/master/inst/scripts/add_cranapt_noble.sh | sh
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  r-base r-base-dev r-recommended \
  r-cran-docopt r-cran-littler r-cran-remotes \
  python3-dbus python3-gi python3-apt sudo \
  && Rscript -e 'install.packages("bspm")'  \
  ## Support user-level installation of R packages
  && chown root:staff /usr/lib/R/site-library \
  && chmod g+ws /usr/lib/R/site-library \
  && echo "options(bspm.sudo = TRUE)" >> /usr/lib/R/etc/Rprofile.site

## add user to sudoers
RUN echo "${NB_USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

## RStudio
RUN conda install jupyter-rsession-proxy
COPY install_rstudio.sh install_rstudio.sh
RUN bash install_rstudio.sh

USER ${NB_USER}

