# syntax=docker/dockerfile:1
#
# The atima server image. Build it from the repository root:
#
#   docker build -f deploy/Dockerfile -t atima .
#
# or let `docker compose` do it (deploy/compose.yaml). Nothing here is a
# secret and nothing is configured here: every setting of atima::run() is an
# environment variable, ATIMA_<NAME>, given when the container starts.

ARG R_VERSION=4.6

FROM rocker/r-ver:${R_VERSION}

# What the R packages need at run time: pandoc turns a BIOM file's comment
# into a description, the image libraries draw figures (ragg, svglite),
# cmake and the rest compile the few packages that have no binary. curl is
# for the health check, and dumb-init passes stop signals on to R.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      cmake \
      curl \
      dumb-init \
      git \
      libcurl4-openssl-dev \
      libfontconfig1-dev \
      libfreetype6-dev \
      libfribidi-dev \
      libharfbuzz-dev \
      libjpeg-dev \
      libpng-dev \
      libssl-dev \
      libtiff-dev \
      libwebp-dev \
      libxml2-dev \
      pandoc \
      zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# Packages that rbiom and atima only suggest, but that decide what a server
# offers. Without one of these atima quietly leaves out what needs it, so
# this list is the place to get right:
#   openxlsx     Excel export
#   fillpattern  the `patterns` parameter of the plots
#   Rtsne, uwot  tSNE and UMAP ordinations
#   ggdensity    the density layer of ordinations
#   lmerTest     `strata` in taxa_forest
#   ggbeeswarm, ggrepel   nicer layers (rbiom has fallbacks)
#   h5lite       HDF5 BIOM files
#   svglite      SVG figures
#   bcrypt       importing from atima 2 (the server refuses to start with a
#                legacy file and no bcrypt)
ARG OPTIONAL_PACKAGES="openxlsx fillpattern Rtsne uwot ggdensity lmerTest ggbeeswarm ggrepel h5lite svglite bcrypt"

# (A build argument is an environment variable while a RUN step runs.)
RUN Rscript -e 'pkgs <- strsplit(Sys.getenv("OPTIONAL_PACKAGES"), " ")[[1]]; \
      install.packages(c("remotes", pkgs)); \
      missing <- setdiff(pkgs, rownames(installed.packages())); \
      if (length(missing)) stop("Not installed: ", paste(missing, collapse = ", "))'

# What atima imports, in a layer of its own so that a change to atima's code
# does not install it all again. rbiom 4 comes from GitHub (the Remotes
# field in DESCRIPTION) until it is on CRAN. An optional GitHub token,
# passed as a build secret and never stored in the image, only raises
# GitHub's rate limit:  docker build --secret id=github_pat,env=GITHUB_PAT ...
COPY DESCRIPTION /src/atima/

RUN --mount=type=secret,id=github_pat,required=false \
    GITHUB_PAT="$(cat /run/secrets/github_pat 2>/dev/null || true)" \
    Rscript -e 'remotes::install_deps("/src/atima", dependencies = c("Depends", "Imports", "LinkingTo"), upgrade = "never")' \
 && rm -rf /tmp/*

# atima itself.
COPY NAMESPACE LICENSE /src/atima/
COPY R    /src/atima/R
COPY inst /src/atima/inst
COPY man  /src/atima/man

RUN Rscript -e 'remotes::install_local("/src/atima", dependencies = FALSE, upgrade = "never")' \
 && Rscript -e 'message("atima ", packageVersion("atima"), " with rbiom ", packageVersion("rbiom"))' \
 && rm -rf /src /tmp/*

COPY deploy/entrypoint.sh deploy/backup.R /opt/atima/
RUN chmod 0555 /opt/atima/entrypoint.sh

# An unprivileged user, and the two directories the server writes to. Mount a
# volume on each: the data directory holds the database and the stored
# files; the temporary directory holds figures and exports, is emptied of
# old files by the server, and must not be inside the data directory.
RUN useradd --uid 10001 --user-group --no-create-home --shell /usr/sbin/nologin atima \
 && mkdir -p /var/lib/atima /var/tmp/atima /backup \
 && chown atima:atima /var/lib/atima /var/tmp/atima /backup

USER atima

# The user has no home directory; R looks for one.
ENV HOME=/tmp \
    ATIMA_HOST=0.0.0.0 \
    ATIMA_PORT=8080 \
    ATIMA_AUTH=oidc \
    ATIMA_DATA_DIR=/var/lib/atima \
    ATIMA_TEMP_DIR=/var/tmp/atima \
    ATIMA_OPEN=false

VOLUME ["/var/lib/atima", "/var/tmp/atima"]
EXPOSE 8080

# An interrupt (SIGINT) is what stops atima cleanly: it cancels running
# jobs, stops its worker processes and checkpoints the database. A SIGTERM,
# which is what most things that stop containers send, would end R on the
# spot, so dumb-init turns it into an interrupt for R (and for R only: atima
# stops its own workers). Allow 30 seconds (`stop_grace_period`).
STOPSIGNAL SIGINT

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:8080/api/health || exit 1

ENTRYPOINT ["dumb-init", "--single-child", "--rewrite", "15:2", "--", "/opt/atima/entrypoint.sh"]
CMD ["server"]
