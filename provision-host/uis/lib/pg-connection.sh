#!/bin/bash
# pg-connection.sh — how UIS code reaches PostgreSQL from inside its pod.
#
# ⚠️ ALWAYS PASS A HOST. NEVER RELY ON THE LOCAL SOCKET.
#
# UIS code reaches Postgres by exec'ing into "the postgres pod" and running
# psql. Without `-h`, psql connects over the local unix socket — which exists
# only if a Postgres SERVER is running in that container.
#
# On the in-cluster topology it is, so the socket works and nothing fails.
#
# On the proxied topology (an installation that declares postgresql in
# .uis.extend/external-services.yaml) the first container is a `postgres:18`
# image running `sleep infinity` — CLIENT TOOLING ONLY. There is no server and
# no socket. Every socket connection fails with:
#
#     psql: error: connection to server on socket
#           "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory
#
# and the caller, if it swallowed stderr, reported that as "the database does
# not exist" — about a database that did exist. A topology failure reported as a
# data problem. Found on production by ops (2026-08-25), the fourth defect that
# day from an assumption true only of the development topology.
#
# 127.0.0.1 rather than the Service name deliberately: it stays inside the pod
# and does not depend on cluster DNS. On the proxy it reaches the socat sidecar,
# which is the path the proxy exists to provide; in-cluster it reaches the local
# server over TCP.
PG_PSQL_HOST="${PG_PSQL_HOST:-127.0.0.1}"
