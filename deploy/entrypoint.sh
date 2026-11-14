#!/bin/sh
# Entry point of the atima image.
#
#   server             run the atima server (the default)
#   backup-loop        make a backup every night (the `backup` service)
#   backup             make one backup now
#   restore <name>     put a backup back; the server must be stopped
#   backups            list the backups there are
#
# A setting that is a secret can be given as a file instead of a value, for
# Docker or Kubernetes secrets: ATIMA_OIDC_CLIENT_SECRET_FILE names a file
# whose contents become ATIMA_OIDC_CLIENT_SECRET.
set -eu

if [ -n "${ATIMA_OIDC_CLIENT_SECRET_FILE:-}" ]; then
  ATIMA_OIDC_CLIENT_SECRET="$(cat "$ATIMA_OIDC_CLIENT_SECRET_FILE")"
  export ATIMA_OIDC_CLIENT_SECRET
fi

case "${1:-server}" in

  server)
    # `exec`, so that R is the process that gets the stop signal. R shuts
    # atima down cleanly when it is interrupted: running jobs are cancelled,
    # the worker processes stopped and the database checkpointed.
    exec Rscript -e 'tryCatch(atima::run(), interrupt = function (e) invisible(NULL))'
    ;;

  backup|backup-loop|restore|backups)
    exec Rscript /opt/atima/backup.R "$@"
    ;;

  *)
    exec "$@"
    ;;
esac
