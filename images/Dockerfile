FROM rocker/geospatial 
RUN /scripts/install_binder.sh

COPY requirements.txt requirements.txt
RUN python -m pip install -r requirements.txt && rm requirements.txt
COPY install.R install.R
RUN Rscript install.R && rm install.R
RUN python -m ipykernel install --user --name=nasa

# some teaching preferences
RUN git config --global pull.rebase false


