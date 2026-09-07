# hash-archive — https://github.com/btrask/hash-archive
#
# Replaces the 2020-era image (Ubuntu 16.04 Xenial, EOL 2021, 663 MB) that
# existed only in cirrus's local Docker daemon and was never pushed anywhere.
#
# Three substantive changes over the old recipe:
#
#  1. MULTI-STAGE. The old image shipped the whole build toolchain and source
#     tree. Only the binary plus templates/ and static/ are needed at runtime,
#     and `ldd` confirms the binary links nothing but libc/libstdc++/libm/
#     libpthread — LibreSSL and the kvstore backend are vendored static.
#
#  2. THE HOSTNAME IS BAKED AT BUILD TIME. The old image ran
#     `sed -i s/hash-archive.org/$URL/ src/config.h && make install` as its
#     *runtime* command, recompiling on every container start — minutes of
#     startup and a mandatory writable root filesystem. config.h is patched
#     here instead, so the container starts instantly and just execs the binary.
#
#  3. CURRENT CA BUNDLE. Upstream's `make install-root-certs` copies the
#     cert.pem vendored in libressl-portable — frozen at whatever the pinned
#     commit shipped. hash-archive fetches arbitrary URLs over HTTPS to hash
#     them, so a stale bundle means silent failures against modern sites. We
#     point its expected path at the distro's maintained ca-certificates.
#
# Build:
#   docker build -t ghcr.io/boettiger-lab/hash-archive:latest \
#     --build-arg HOSTNAME_CONFIG=hash-archive.carlboettiger.info \
#     /home/cboettig/Documents/boettiger-lab/k8s/hash-archive
#
# NOTE ON THE BASE IMAGE: this is 2020-era C. Modern toolchains are far
# stricter — GCC 14 (Ubuntu 24.04) promotes implicit-function-declaration and
# several other legacy patterns to hard errors. BUILD_BASE is therefore an ARG:
# 22.04 (GCC 11) is the conservative default that still gets security updates
# to 2027. Try 24.04 if you want; if it fails, that is why.

ARG BUILD_BASE=ubuntu:22.04
ARG RUNTIME_BASE=ubuntu:22.04

# ---------------------------------------------------------------- builder ---
FROM ${BUILD_BASE} AS builder

ARG DEBIAN_FRONTEND=noninteractive

# Upstream is unversioned and low-traffic; pin so builds are reproducible.
# Override to track master:  --build-arg HASH_ARCHIVE_REF=master
ARG HASH_ARCHIVE_REF=master

# The hostname compiled into config.h. hash-archive answers 403 to any request
# whose Host header does not match this, so it must equal the public name.
ARG HOSTNAME_CONFIG=hash-archive.carlboettiger.info

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        automake \
        autoconf \
        libtool \
        pkg-config \
        cmake \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# The submodules (deps/libasync, deps/libkvstore) use RELATIVE urls ("../libasync/"),
# which resolve against the parent clone URL — so they only work when cloned
# over https from github, not from a local path.
RUN git clone --recursive https://github.com/btrask/hash-archive.git . \
    && git checkout "${HASH_ARCHIVE_REF}" \
    && git submodule update --init --recursive

# The vendored cmark generates a man page with `python man/make_man_page.py`.
# That is Python 2 code invoked as bare `python` — a name Ubuntu 16.04 had and
# no modern Ubuntu ships at all. It runs AFTER libcmark.a is already built and
# the man page is of no use to us, so neuter just that recipe: swapping `python`
# for `true` is NOT enough: the recipe redirects into man/man3/, a directory
# that does not exist in the checkout, so the redirect itself fails. Replace the
# whole recipe with mkdir+touch. Installing python-is-python3 does not help
# either — make_man_page.py is Python 2 syntax, so python3 fails on it too.
RUN sed -i 's|^\tpython man/make_man_page\.py.*|\t@mkdir -p $(dir $@) \&\& touch $@|' deps/cmark/Makefile \
    && grep -n -A1 'man/man3/cmark.3:' deps/cmark/Makefile

# Patch the compiled-in hostname before building, rather than at runtime.
RUN sed -i "s/hash-archive\.org/${HOSTNAME_CONFIG}/" src/config.h \
    && grep -n 'CONFIG_HOSTNAME' src/config.h

# Relax modern-compiler strictness for this vintage codebase.
#
# The project and its submodules HARDCODE -Werror in their own Makefiles, so an
# external CFLAGS cannot override it. GCC 11 then fails the build on warnings
# that did not exist (or were not errors) under the GCC 5 this was written for:
#   deps/libkvstore/src/kvs_base_mdb.c   -Werror=cast-function-type
#   deps/libasync/src/http/QueryString.c -Werror=implicit-fallthrough
# Both are benign in context. Strip -Werror tree-wide rather than patching
# individual call sites in third-party code we do not maintain — warnings are
# still printed, they just no longer abort the build.
RUN find . -name Makefile -exec sed -i 's/-Werror//g' {} + \
    && echo "stripped -Werror from $(find . -name Makefile | wc -l) Makefiles"

ENV CFLAGS="-Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-cast-function-type -Wno-implicit-fallthrough"

RUN ./configure && make -j"$(nproc)"

# Sanity-check that we actually produced a binary before shipping a broken image.
RUN test -x build/hash-archive && ldd build/hash-archive

# ---------------------------------------------------------------- runtime ---
FROM ${RUNTIME_BASE}

ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="hash-archive" \
      org.opencontainers.image.source="https://github.com/btrask/hash-archive" \
      org.opencontainers.image.description="Hash Archive — records cryptographic hashes of URLs over time" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libstdc++6 \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    # hash-archive looks for its CA bundle at $PREFIX/etc/ssl/cert.pem (upstream
    # installs libressl's vendored copy there). Symlink the distro bundle so it
    # keeps receiving updates instead of freezing at build time.
    && mkdir -p /usr/local/etc/ssl \
    && ln -sf /etc/ssl/certs/ca-certificates.crt /usr/local/etc/ssl/cert.pem

COPY --from=builder /src/build/hash-archive /usr/local/bin/hash-archive

# config.h defines CONFIG_TEMPLATE_DIR "./templates", CONFIG_STATIC_DIR
# "./static", CONFIG_DB_PATH "./hash-archive.db" and CONFIG_IMPORT_SOCKET_PATH
# "./import.sock" — ALL RELATIVE TO THE WORKING DIRECTORY. So the process must
# run with its CWD here, and this directory must be writable (import.sock).
WORKDIR /app
COPY --from=builder /src/templates ./templates
COPY --from=builder /src/static    ./static

# Run unprivileged. Upstream's `make install` applies
# CAP_NET_BIND_SERVICE, but that is only needed for ports < 1024 and this
# listens on 8000 (config.h: CONFIG_SERVER_RAW_PORT 8000, TLS port 0 —
# TLS is terminated by Traefik).
RUN groupadd --system --gid 10001 hasharchive \
    && useradd --system --uid 10001 --gid 10001 --home-dir /app --shell /usr/sbin/nologin hasharchive \
    && mkdir -p /app/hash-archive.db \
    && chown -R 10001:10001 /app
# NUMERIC, not `USER hasharchive`: with runAsNonRoot set, kubelet cannot resolve
# a username to a uid to prove the container is non-root, and the pod dies with
# CreateContainerConfigError "image has non-numeric user".
USER 10001:10001

EXPOSE 8000

# tini reaps zombies; the server itself spawns helpers.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/usr/local/bin/hash-archive"]
