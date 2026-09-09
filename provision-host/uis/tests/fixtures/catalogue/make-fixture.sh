#!/bin/bash
# make-fixture.sh — build the catalogue fixture: an OCI artifact and a registry
# entry pointing at it, so `uis template install` can be exercised without
# waiting on dev-templates to emit source.* or on a tenant to publish anything.
#
# Usage, from inside uis-provision-host:
#
#   bash provision-host/uis/tests/fixtures/catalogue/make-fixture.sh
#   # then, as it prints:
#   REGISTRY_URL_PRIMARY=file://$OUT/registry.json UIS_ORAS_OCI_LAYOUT=1 \
#       ./uis template install uisfix --dry-run
#
# ⚠️ UIS_ORAS_OCI_LAYOUT is test surface: it makes `oras pull` read an OCI layout
# on disk instead of a registry. So this exercises resolution, validation,
# planning and the install — everything except the network hop to ghcr.io. That
# hop is what atlas's first real publish will prove; nothing here can.
set -euo pipefail

OUT="${1:-/tmp/uis-catalogue-fixture}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="v20260909-fixture"

for t in oras yq jq; do
    command -v "$t" >/dev/null 2>&1 || { echo "need $t (uis-provision-host 1.6.16+ has oras)" >&2; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT"
cp -r "$HERE/definition" "$OUT/definition"

echo "→ pushing the definition as an OCI artifact to an on-disk layout"
( cd "$OUT/definition" \
  && oras push --oci-layout "$OUT/layout:$TAG" \
        template-info.yaml \
        migrations/001_create.sql migrations/026_alter.sql migrations/050_final.sql >/dev/null )

DIGEST="$(oras manifest fetch --oci-layout --descriptor "$OUT/layout:$TAG" \
          | jq -r '.digest')"
echo "  digest: $DIGEST"

# The registry shape the generator will emit (PLAN-templates-002, "The seam").
# templateKind is reused rather than adding a third discriminator.
jq -n --arg art "$OUT/layout" --arg tag "$TAG" --arg dig "$DIGEST" '{
  generated: "fixture",
  categories: [],
  templates: [{
    id: "uisfix",
    name: "UIS Catalogue Fixture",
    description: "Fixture application exercising every config key",
    folder: "uis-applications/uisfix",
    install_type: "stack",
    templateKind: "application",
    visibility: "public",
    source: { artifact: $art, tag: $tag, digest: $dig }
  }]
}' > "$OUT/registry.json"

cat <<EOF

Fixture built in $OUT

  Dry run (no cluster needed):
    REGISTRY_URL_PRIMARY=file://$OUT/registry.json UIS_ORAS_OCI_LAYOUT=1 \\
        ./uis template install uisfix --dry-run

  Install (needs a cluster with postgresql, and will deploy dagster + postgrest):
    REGISTRY_URL_PRIMARY=file://$OUT/registry.json UIS_ORAS_OCI_LAYOUT=1 \\
        ./uis template install uisfix

  Remove (keeps the database unless --purge):
    ./uis template remove uisfix

  Negative cases worth running:
    # not allowlisted — an on-disk layout is not ghcr.io/{helpers-no,terchris}/*
    #   so the install above only works because make-fixture adds it; see below
    # mutable pin
    jq '.templates[0].source.tag = "latest"' $OUT/registry.json > $OUT/bad-tag.json
    # no digest
    jq 'del(.templates[0].source.digest)'   $OUT/registry.json > $OUT/no-digest.json
EOF
