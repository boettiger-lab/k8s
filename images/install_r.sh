#!/bin/bash

## First: update apt and get keys
apt update -qq && apt install --yes --no-install-recommends wget ca-certificates gnupg
wget -q -O- https://eddelbuettel.github.io/r2u/assets/dirk_eddelbuettel_key.asc \
    | tee -a /etc/apt/trusted.gpg.d/cranapt_key.asc

## Second: add the repo -- here we use the well-connected mirror
echo "deb [arch=amd64] https://r2u.stat.illinois.edu/ubuntu noble main" > /etc/apt/sources.list.d/cranapt.list
apt update

## Third: ensure current R is used
wget -q -O- https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
    | tee -a /etc/apt/trusted.gpg.d/cran_ubuntu_key.asc
echo "deb [arch=amd64] https://cloud.r-project.org/bin/linux/ubuntu noble-cran40/" > /etc/apt/sources.list.d/cran_r.list
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 67C2D66C4B1D4339 51716619E084DAB9
apt update -qq
DEBIAN_FRONTEND=noninteractive apt install --yes --no-install-recommends r-base r-base-dev r-recommended 

## Fourth: add pinning to ensure package sorting
echo "Package: *" > /etc/apt/preferences.d/99cranapt
echo "Pin: release o=CRAN-Apt Project" >> /etc/apt/preferences.d/99cranapt
echo "Pin: release l=CRAN-Apt Packages" >> /etc/apt/preferences.d/99cranapt
echo "Pin-Priority: 700"  >> /etc/apt/preferences.d/99cranapt

## Fifth: install bspm (and its Python requirements) and enable it
## If needed (in bare container, say) install python tools for bspm and R itself
apt install --yes --no-install-recommends python3-{dbus,gi,apt} \
	make sudo r-cran-{docopt,littler,remotes} 
## Then install bspm (as root) and enable it, and enable a speed optimization
Rscript -e 'install.packages("bspm")'
RHOME=$(R RHOME)
echo "suppressMessages(bspm::enable())" >> ${RHOME}/etc/Rprofile.site
echo "options(bspm.version.check=FALSE)" >> ${RHOME}/etc/Rprofile.site

chown root:staff ${RHOME}/site-library
chmod g+ws ${RHOME}/site-library
echo "options('bspm.sudo' = TRUE)" >> ${RHOME}/etc/Rprofile.site


ln -s /usr/lib/R/site-library/littler/examples/install2.r /usr/local/bin/install2.r


## add user to sudoers
usermod -a -G staff ${NB_USER}
echo "${NB_USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers


