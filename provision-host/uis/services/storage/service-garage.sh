#!/bin/bash
# service-garage.sh - Garage service metadata
#
# Garage is an S3-compatible object storage server, maintained by Deuxfleurs (a
# French hosting cooperative). It gives applications a bucket/object API with
# no cloud dependency and no account.
#
# 🔴 Why this exists: MinIO's images were withdrawn from every public registry
# on 2026-10-01 (urb-agents#1801) - not account-gated, actually gone. UIS's own
# `uis deploy minio` cannot succeed on a cluster with no cached image. Terje
# decided the same day: do the replacement. See
# INVESTIGATE-service-minio-to-garage.md for the measurement behind this.
#
# ⚠️ Not a drop-in in every respect - see garage.md "What is different from
# MinIO" before assuming parity.

# === Service Metadata (Required) ===
SCRIPT_ID="garage"
SCRIPT_NAME="Garage"
SCRIPT_DESCRIPTION="S3-compatible object storage"
SCRIPT_CATEGORY="STORAGE"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="047-setup-garage.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app=garage --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="047-remove-garage.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="36"

# === Deployment Details (Optional) ===
# No Helm chart. Garage's own chart lives only in its git repository (no
# Helm-repo index, no versioned .tgz), needs a CustomResourceDefinition for one
# discovery mode, and is built for a real multi-node geo-distributed cluster -
# manual `garage layout assign`/`apply`, two PVCs per replica. None of that fits
# a single dev-laptop instance. UIS instead runs the official image directly,
# using the `--single-node --default-bucket` bootstrap that ships since v2.3.0,
# which accepts a CHOSEN access key/secret and needs no layout step at all.
SCRIPT_HELM_CHART=""
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"          # Component | Resource
SCRIPT_TYPE="object-storage"    # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"    # platform-team | app-team

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="S3-compatible object storage for files, images, and backups"
SCRIPT_LOGO="garage-logo.svg"
SCRIPT_WEBSITE="https://garagehq.deuxfleurs.fr"
SCRIPT_TAGS="object-storage,s3,buckets,files,images,blob-storage"
SCRIPT_SUMMARY="Garage is a lightweight, S3-compatible object storage server maintained by Deuxfleurs. Applications talk to it with any AWS S3 SDK. Deployed here as a single node with one bootstrap bucket and access key, an S3 API on port 3900, and no web console - Garage ships none. Replaces MinIO, whose images were withdrawn from every public registry on 2026-10-01."
SCRIPT_DOCS="/docs/services/storage/garage"

# === Template Integration (Optional) ===
# The S3 API port is what applications need on the host machine
# (./uis expose garage -> localhost:39901, chosen to not collide with MinIO's
# 39900 while both services exist side by side during the transition).
SCRIPT_EXPOSE_PORT="39901"
