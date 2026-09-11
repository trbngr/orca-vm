#!/usr/bin/env bash
exec "$(dirname "$0")/podman-lifecycle.sh" resume "$@"
