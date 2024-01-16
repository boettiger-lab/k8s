FROM rocker/geospatial 
ENV NB_USER rstudio
ENV VIRTUAL_ENV /opt/venv

RUN /rocker_scripts/install_jupyter.sh

COPY install.R install.R
RUN Rscript install.R && rm install.R

# some teaching preferences
RUN git config --global pull.rebase false


EXPOSE 8888
CMD ["/bin/sh", "-c", "jupyter lab --ip 0.0.0.0 --no-browser"]

RUN chown -R root:staff ${VIRTUAL_ENV}
USER ${NB_USER}
COPY requirements.txt requirements.txt
RUN python3 -m pip install -r requirements.txt && rm requirements.txt
RUN python3 -m ipykernel install --user --name=spatial


WORKDIR /home/${NB_USER}

