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
#
# 🔴 THE ID AND THE app_name DIFFER ON PURPOSE: `uisfix` is installed, and every
# per-app resource is named `uisfixapp`. They used to be the same string, and
# that is why four rounds of this fixture passed over a `template remove` that
# derived per-app names from the record ID — on a real cluster with a real
# override, its plan named somebody else's live instance (urb-agents#481).
#
# So when you read the plan this prints, check BOTH names appear where they
# should: `uisfix` only as the application, `uisfixapp` on every --app,
# database, secret prefix, url-prefix and code location.
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

# 🔴 Actually create the allowlist entry rather than claiming to.
#
# This script used to print `./uis template install uisfix` and, two lines
# below, say "the install above only works because make-fixture adds it" — and
# make-fixture added nothing. Every command it printed failed with
# "Artifact ... is not in the allowlist". A test fixture whose own instructions
# do not run is the same defect the fixture exists to catch, one level up.
#
# Written into an extend dir the fixture OWNS, not the installation's: a test
# script must not widen what a real installation trusts.
mkdir -p "$OUT/extend"
cat > "$OUT/extend/template-allowlist.conf" <<CONF
# Written by make-fixture.sh. Lets the on-disk OCI layout below be pulled.
# ⚠️ Scoped to this fixture: point EXTEND_DIR at this directory, never merge
# this line into a real installation's allowlist.
$OUT/layout
CONF

cat <<EOF

Fixture built in $OUT

⚠️ EXTEND_DIR is required: it carries the allowlist entry for the on-disk
   layout, and the fixture's own .uis.extend so nothing touches the real one.

  Dry run (no cluster needed):
    REGISTRY_URL_PRIMARY=file://$OUT/registry.json UIS_ORAS_OCI_LAYOUT=1 \\
    EXTEND_DIR=$OUT/extend \\
        ./uis template install uisfix --dry-run

  Install (needs a cluster with postgresql, and will deploy dagster + postgrest):
    REGISTRY_URL_PRIMARY=file://$OUT/registry.json UIS_ORAS_OCI_LAYOUT=1 \\
    EXTEND_DIR=$OUT/extend \\
        ./uis template install uisfix

  Remove (keeps the database unless --purge):
    EXTEND_DIR=$OUT/extend ./uis template remove uisfix

  🔴 Read the plan and check BOTH names land where they should. The id and the
     app_name differ on purpose:
       uisfix      the application id — should appear ONLY as the application
       uisfixapp   every --app, database, secret prefix, url-prefix, code location

  Negative cases worth running:
    # not allowlisted — drop EXTEND_DIR and the layout is refused by name
    REGISTRY_URL_PRIMARY=file://$OUT/registry.json UIS_ORAS_OCI_LAYOUT=1 \\
        ./uis template install uisfix --dry-run
    # mutable pin
    jq '.templates[0].source.tag = "latest"' $OUT/registry.json > $OUT/bad-tag.json
    # no digest
    jq 'del(.templates[0].source.digest)'   $OUT/registry.json > $OUT/no-digest.json
EOF
