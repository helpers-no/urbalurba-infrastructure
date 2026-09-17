#!/bin/bash
# test-templates-structure.sh - Validate template directory structure
#
# TEMPORARY TEST: Validates the new secrets/hosts template structure.
# This will be superseded by integration tests in PLAN-002.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

# Determine templates path (works both in container and on host)
if [[ -d "/mnt/urbalurbadisk/provision-host/uis/templates" ]]; then
    TEMPLATES_DIR="/mnt/urbalurbadisk/provision-host/uis/templates"
else
    TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../../templates" && pwd)"
fi

print_test_section "Template Structure Tests"
echo "Templates directory: $TEMPLATES_DIR"

# Secret templates
start_test "uis.secrets/defaults.env.template exists"
assert_file_exists "$TEMPLATES_DIR/uis.secrets/defaults.env.template" && pass_test

start_test "uis.secrets/cloud-accounts/azure.env.template exists"
assert_file_exists "$TEMPLATES_DIR/uis.secrets/cloud-accounts/azure.env.template" && pass_test

start_test "uis.secrets/cloud-accounts/gcp.env.template exists"
assert_file_exists "$TEMPLATES_DIR/uis.secrets/cloud-accounts/gcp.env.template" && pass_test

start_test "uis.secrets/service-keys/cloudflare.env.template exists"
assert_file_exists "$TEMPLATES_DIR/uis.secrets/service-keys/cloudflare.env.template" && pass_test

start_test "uis.secrets/network/wifi.env.template exists"
assert_file_exists "$TEMPLATES_DIR/uis.secrets/network/wifi.env.template" && pass_test

# Host config templates
start_test "uis.extend/hosts/managed/azure-aks.conf.template exists"
assert_file_exists "$TEMPLATES_DIR/uis.extend/hosts/managed/azure-aks.conf.template" && pass_test

start_test "uis.extend/hosts/cloud-vm/azure-microk8s.conf.template exists"
assert_file_exists "$TEMPLATES_DIR/uis.extend/hosts/cloud-vm/azure-microk8s.conf.template" && pass_test

start_test "uis.extend/hosts/physical/raspberry-pi.conf.template exists"
assert_file_exists "$TEMPLATES_DIR/uis.extend/hosts/physical/raspberry-pi.conf.template" && pass_test

start_test "uis.extend/hosts/local/rancher-desktop.conf.template exists"
assert_file_exists "$TEMPLATES_DIR/uis.extend/hosts/local/rancher-desktop.conf.template" && pass_test

# Cloud-init templates (complementary to host configs)
start_test "ubuntu-cloud-init/azure-cloud-init-template.yml exists"
assert_file_exists "$TEMPLATES_DIR/ubuntu-cloud-init/azure-cloud-init-template.yml" && pass_test

start_test "ubuntu-cloud-init/raspberry-cloud-init-template.yml exists"
assert_file_exists "$TEMPLATES_DIR/ubuntu-cloud-init/raspberry-cloud-init-template.yml" && pass_test

start_test "ubuntu-cloud-init/multipass-cloud-init-template.yml exists"
assert_file_exists "$TEMPLATES_DIR/ubuntu-cloud-init/multipass-cloud-init-template.yml" && pass_test

# Verify host configs have required settings
start_test "raspberry-pi.conf.template has HOSTNAME"
if grep -q "^HOSTNAME=" "$TEMPLATES_DIR/uis.extend/hosts/physical/raspberry-pi.conf.template"; then
    pass_test
else
    fail_test "Missing HOSTNAME setting"
fi

start_test "azure-microk8s.conf.template has CREDENTIALS"
if grep -q "^CREDENTIALS=" "$TEMPLATES_DIR/uis.extend/hosts/cloud-vm/azure-microk8s.conf.template"; then
    pass_test
else
    fail_test "Missing CREDENTIALS setting"
fi

# cloudflare.env.template must document only credentials something reads.
# It shipped CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID until 1.6.117 — no
# playbook has ever read either, so the template was asking operators to create
# a Cloudflare API token the tunnel never uses. The tunnel token is the only
# credential (820-deploy + 822-verify read it); BASE_DOMAIN_CLOUDFLARE is
# optional and only gates verify's end-to-end probe.
start_test "cloudflare.env.template has CLOUDFLARE_TUNNEL_TOKEN"
if grep -q "^CLOUDFLARE_TUNNEL_TOKEN=" "$TEMPLATES_DIR/uis.secrets/service-keys/cloudflare.env.template"; then
    pass_test
else
    fail_test "Missing CLOUDFLARE_TUNNEL_TOKEN — the tunnel's only credential"
fi

start_test "cloudflare.env.template documents no unread credentials"
if grep -qE '^#?[[:space:]]*(CLOUDFLARE_API_TOKEN|CLOUDFLARE_ZONE_ID)=' \
        "$TEMPLATES_DIR/uis.secrets/service-keys/cloudflare.env.template"; then
    fail_test "Reintroduced CLOUDFLARE_API_TOKEN/CLOUDFLARE_ZONE_ID — nothing reads these"
else
    pass_test
fi

# Note: Cloud-init template selection is handled by CLI code (PLAN-002),
# not by config files. The mapping is: host-type -> cloud-init-template

# Summary
print_summary
