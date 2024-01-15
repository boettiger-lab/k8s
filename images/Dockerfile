FROM rocker/geospatial 
RUN /rocker_scripts/install_jupyter.sh

COPY requirements.txt requirements.txt
RUN python3 -m pip install -r requirements.txt && rm requirements.txt
COPY install.R install.R
RUN Rscript install.R && rm install.R
RUN python3 -m ipykernel install --user --name=nasa

# some teaching preferences
RUN git config --global pull.rebase false


