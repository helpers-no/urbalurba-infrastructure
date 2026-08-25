#!/bin/bash
# configure-postgrest.sh — PostgREST handler for uis configure
#
# PostgREST is a multi-instance service: each consuming application gets its own
# Deployment in the shared postgrest namespace, configured separately. This handler
# creates per-app Postgres roles in the platform's PostgreSQL instance, generates a
# password, and writes a secret in the postgrest namespace that the per-app
# PostgREST Deployment will mount.
#
# See:
#   - INVESTIGATE-postgrest.md (decisions, addendum on ALTER DEFAULT PRIVILEGES)
#   - PLAN-002-postgrest-deployment.md Phase 2

# PostgreSQL connection details (where we create the roles)

# See pg-connection.sh — ALWAYS pass -h. The local socket does not exist on the
# proxied topology. Defined defensively here so this lib works even when sourced
# outside uis-cli.sh.
PG_PSQL_HOST="${PG_PSQL_HOST:-127.0.0.1}"

PG_ADMIN_USER="postgres"
PG_K8S_SVC="postgresql"
PG_NAMESPACE="default"
PG_INTERNAL_PORT=5432
PG_CLUSTER_HOST="postgresql.default.svc.cluster.local"

# PostgREST namespace (where the per-app Deployment + Secret live)
PGRST_NAMESPACE="postgrest"

# Normalize a --schemas value into a comma-separated list of valid Postgres
# identifiers. Implements R4 string-level checks from the investigation:
#   1. Trim whitespace per component
#   2. Reject empty value or empty components after trim
#   3. Reject components not matching ^[a-zA-Z_][a-zA-Z0-9_]*$ (SQL-injection guard)
#   4. De-dupe with a stderr warning (preserves first occurrence)
# Prints the normalized value to stdout on success; prints an error to stderr
# and returns non-zero on rejection. The R4 step-4 existence check (does the
# schema actually exist in pg_namespace) is wired separately at call time —
# this helper is pure (no DB I/O) and safe to test in isolation.
_pgrst_normalize_schemas() {
    local raw="$1"
    local -a parts=()
    local seen=""
    local part trimmed
    local IFS=','

    if [[ -z "$raw" ]]; then
        echo "Schema list is empty. Pass --schemas <list> with at least one schema name." >&2
        return 1
    fi

    # Catch leading/trailing comma before bash IFS field-splitting drops
    # the empty trailing field. (Leading commas show up as the first split
    # being empty and are caught by the per-component empty check below.)
    if [[ "$raw" == *, ]]; then
        echo "Schema list contains an empty component (trailing comma)." >&2
        return 1
    fi

    for part in $raw; do
        # Trim leading/trailing whitespace
        trimmed="${part#"${part%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

        if [[ -z "$trimmed" ]]; then
            echo "Schema list contains an empty component (consecutive commas or trailing comma)." >&2
            return 1
        fi

        if ! [[ "$trimmed" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            echo "Schema name '$trimmed' is not a valid Postgres identifier (must match ^[a-zA-Z_][a-zA-Z0-9_]*\$)." >&2
            return 1
        fi

        # De-dupe (case-sensitive; for the platform's intended use, exact
        # match is sufficient — Postgres folds unquoted identifiers to
        # lowercase but operators are expected to pass already-lowercase
        # names since the regex above forbids mixed-case ambiguity in
        # practice).
        if [[ ",$seen," == *",$trimmed,"* ]]; then
            # log_warn writes to stdout by project convention; force it to
            # stderr here so it doesn't corrupt the normalizer's stdout
            # output (which is the normalized schema list).
            log_warn "Duplicate schema '$trimmed' in --schemas list; ignoring the duplicate." >&2
            continue
        fi

        parts+=("$trimmed")
        seen="${seen:+$seen,}$trimmed"
    done

    if [[ ${#parts[@]} -eq 0 ]]; then
        echo "Schema list is empty after de-duplication." >&2
        return 1
    fi

    # Join with commas, no spaces
    local out=""
    for part in "${parts[@]}"; do
        out="${out:+$out,}$part"
    done
    printf '%s' "$out"
}

# Get the postgresql admin password from urbalurba-secrets
_pgrst_get_admin_password() {
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    kubectl get secret urbalurba-secrets \
        -n "$PG_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -o jsonpath='{.data.PGPASSWORD}' 2>/dev/null | base64 -d
}

# Find the postgresql pod name
_pgrst_get_pod() {
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    kubectl get pods -n "$PG_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -l app.kubernetes.io/name=postgresql \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Run a SQL command as the postgres admin user (default database).
# Used for cluster-wide queries (pg_roles existence, CREATE/DROP ROLE, ALTER USER).
_pgrst_exec() {
    local sql="$1"
    local admin_pass="$2"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    local pod
    pod=$(_pgrst_get_pod)

    if [[ -z "$pod" ]]; then
        return 1
    fi

    kubectl exec "$pod" \
        -n "$PG_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -- env PGPASSWORD="$admin_pass" psql -h "$PG_PSQL_HOST" -U "$PG_ADMIN_USER" -t -A -c "$sql"
}

# Run a SQL block against a specific database. Mirrors `_pg_exec_db` in
# configure-postgresql.sh. Uses -i + stdin (heredoc) so multi-statement blocks
# work, and merges stderr into stdout so the caller can capture diagnostic
# text on failure (no `2>/dev/null` here — silent failure is what bit us).
_pgrst_exec_db() {
    local sql="$1"
    local admin_pass="$2"
    local database="$3"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    local pod
    pod=$(_pgrst_get_pod)

    if [[ -z "$pod" ]]; then
        return 1
    fi

    printf '%s\n' "$sql" | kubectl exec -i "$pod" \
        -n "$PG_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -- env PGPASSWORD="$admin_pass" psql -h "$PG_PSQL_HOST" -U "$PG_ADMIN_USER" -d "$database" \
           --set ON_ERROR_STOP=on -f - 2>&1
}

# Check if a role exists
_pgrst_role_exists() {
    local role_name="$1"
    local admin_pass="$2"
    local result
    result=$(_pgrst_exec "SELECT 1 FROM pg_roles WHERE rolname='$role_name'" "$admin_pass")
    [[ "$result" == "1" ]]
}

# Check if a secret exists in the postgrest namespace
_pgrst_secret_exists() {
    local secret_name="$1"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    kubectl get secret "$secret_name" -n "$PGRST_NAMESPACE" \
        --kubeconfig="$kubeconf" >/dev/null 2>&1
}

# Check if a per-app Deployment exists (used by --purge to refuse if k8s objects still present)
_pgrst_deployment_exists() {
    local deployment_name="$1"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    kubectl get deployment "$deployment_name" -n "$PGRST_NAMESPACE" \
        --kubeconfig="$kubeconf" >/dev/null 2>&1
}

# Ensure a Kubernetes namespace exists (idempotent)
_pgrst_ensure_namespace() {
    local ns="$1"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    kubectl create namespace "$ns" \
        --kubeconfig="$kubeconf" \
        --dry-run=client -o yaml 2>/dev/null \
        | kubectl apply --kubeconfig="$kubeconf" -f - >/dev/null 2>&1
}

# Create or update the per-app secret with both PGRST_DB_URI and PGRST_DB_SCHEMAS
# keys (idempotent). PGRST_DB_SCHEMAS holds the comma-separated, normalized
# schema list that PostgREST exposes; the deploy template reads it via
# valueFrom.secretKeyRef.
_pgrst_create_secret() {
    local secret_name="$1"
    local db_uri="$2"
    local schemas="$3"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"

    kubectl create secret generic "$secret_name" \
        --namespace="$PGRST_NAMESPACE" \
        --from-literal=PGRST_DB_URI="$db_uri" \
        --from-literal=PGRST_DB_SCHEMAS="$schemas" \
        --kubeconfig="$kubeconf" \
        --dry-run=client -o yaml 2>/dev/null \
        | kubectl apply --kubeconfig="$kubeconf" -f - >/dev/null 2>&1
}

# Read the PGRST_DB_SCHEMAS key from an existing secret (empty string if
# secret or key is missing). Used for State Matrix dispatch.
_pgrst_get_secret_schemas() {
    local secret_name="$1"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    local val
    val=$(kubectl get secret "$secret_name" -n "$PGRST_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -o jsonpath='{.data.PGRST_DB_SCHEMAS}' 2>/dev/null)
    if [[ -n "$val" ]]; then
        printf '%s' "$val" | base64 -d
    fi
}

# Read the PGRST_DB_URI key from an existing secret (empty string if missing).
# Used by Reconfigure-preserve-URI path to round-trip the URI verbatim.
_pgrst_get_secret_uri() {
    local secret_name="$1"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    local val
    val=$(kubectl get secret "$secret_name" -n "$PGRST_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -o jsonpath='{.data.PGRST_DB_URI}' 2>/dev/null)
    if [[ -n "$val" ]]; then
        printf '%s' "$val" | base64 -d
    fi
}

# R4 step 4: verify every schema in the normalized list exists in the target
# database. Prints the offending schema name to stderr and returns 1 on the
# first miss; returns 0 if all exist. Schemas have already passed string-level
# validation (R4 steps 1–3) before this is called, so SQL injection is not a
# concern here.
_pgrst_check_schemas_exist() {
    local schemas="$1"
    local admin_pass="$2"
    local database="$3"
    local IFS=','
    local s result rc=0
    for s in $schemas; do
        result=$(_pgrst_exec_db "SELECT 1 FROM pg_namespace WHERE nspname='$s'" "$admin_pass" "$database") || rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "Failed to query pg_namespace in database '$database' (psql exit $rc): $result" >&2
            return 1
        fi
        # _pgrst_exec_db uses psql's default (verbose) output:
        #     ?column?
        #    ----------
        #            1
        #    (1 row)
        # The row value has leading whitespace, so anchored grep on "^1$"
        # doesn't match. Detect "no rows" via the row-count footer instead:
        # absence of "(0 rows)" + presence of a "(N rows)" footer means at
        # least one row came back, which is what we want.
        if printf '%s\n' "$result" | grep -q '(0 rows)'; then
            echo "Schema '$s' does not exist in database '$database'. Create it first (typically via the consuming app's migration), then retry: ./uis configure postgrest --app <name> --database $database --schemas <list>" >&2
            return 1
        fi
    done
    return 0
}

# Build the per-schema GRANT block (USAGE on schema + SELECT on existing
# tables + DEFAULT PRIVILEGES for future tables) for one role across a
# comma-separated schema list. Caller wraps the result in a transaction.
_pgrst_build_grant_sql() {
    local schemas="$1"
    local role="$2"
    local IFS=','
    local s out=""
    for s in $schemas; do
        out+="GRANT USAGE ON SCHEMA $s TO $role;
GRANT SELECT ON ALL TABLES IN SCHEMA $s TO $role;
ALTER DEFAULT PRIVILEGES IN SCHEMA $s GRANT SELECT ON TABLES TO $role;
"
    done
    printf '%s' "$out"
}

# Issue NOTIFY pgrst, 'reload schema' against the per-app database so the
# live PostgREST refreshes its schema cache. PostgREST's db-channel defaults
# to 'pgrst' on the connected database; no further config needed.
_pgrst_notify_reload() {
    local admin_pass="$1"
    local database="$2"
    _pgrst_exec_db "NOTIFY pgrst, 'reload schema';" "$admin_pass" "$database" >/dev/null 2>&1 || true
}

# Delete the per-app secret
_pgrst_delete_secret() {
    local secret_name="$1"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    kubectl delete secret "$secret_name" -n "$PGRST_NAMESPACE" \
        --kubeconfig="$kubeconf" >/dev/null 2>&1
}

# Main handler — called by configure.sh.
#
# Argument layout matches the run_configure dispatch in configure.sh:
#   $1=service_id $2=app_name $3=database_name $4=init_file $5=json_output
#   $6=namespace $7=secret_name_prefix $8=schemas $9=url_prefix $10=rotate $11=purge
#
# Multi-instance handler convention: namespace/secret_name_prefix come from the
# generic --namespace / --secret-name-prefix flags but PostgREST rejects those
# (Decision #6) — namespace and secret name are platform-decided. We accept the
# args to keep dispatch consistent, then error if either is non-empty.
configure_service() {
    local service_id="$1"
    local app_name="$2"
    local database_name="$3"
    local init_file="$4"  # unused by postgrest
    local json_output="$5"
    local namespace="${6:-}"
    local secret_name_prefix="${7:-}"
    local schemas="${8:-}"
    local url_prefix="${9:-}"
    local rotate="${10:-false}"
    local purge="${11:-false}"

    # Reject flags that don't apply to postgrest (Decision #6)
    if [[ -n "$namespace" || -n "$secret_name_prefix" ]]; then
        local msg="--namespace and --secret-name-prefix are not supported for postgrest. PostgREST manages its own namespace ($PGRST_NAMESPACE) and secret name (<app>-postgrest). Run: ./uis configure postgrest --app <name> --database <name> --schemas api_v1,marts,raw --url-prefix <prefix>"
        if [[ "$json_output" == true ]]; then
            _configure_error "usage" "$service_id" "$msg"
        fi
        log_error "$msg"
        return 1
    fi

    # Defaults (per Decision #16)
    if [[ -z "$database_name" ]]; then
        database_name=$(echo "${app_name}" | tr '-' '_')
    fi
    if [[ -z "$schemas" ]]; then
        schemas="api_v1"
    fi
    if [[ -z "$url_prefix" ]]; then
        url_prefix="api-${app_name}"
    fi

    # Compute role names (always per-app prefixed; Decision #7)
    local app_user
    app_user=$(echo "${app_name}" | tr '-' '_')
    local web_anon_role="${app_user}_web_anon"
    local authenticator_role="${app_user}_authenticator"
    local secret_name="${app_name}-postgrest"
    local deployment_name="${app_name}-postgrest"

    # Get postgresql admin password
    local admin_pass
    admin_pass=$(_pgrst_get_admin_password)
    if [[ -z "$admin_pass" ]]; then
        if [[ "$json_output" == true ]]; then
            _configure_error "create_resources" "$service_id" "Could not read PGPASSWORD from urbalurba-secrets. Run: uis secrets apply"
        fi
        log_error "Could not read PGPASSWORD from urbalurba-secrets"
        return 1
    fi

    # ---- PURGE PATH (Decision #18) ----
    if [[ "$purge" == "true" ]]; then
        # Refuse if a Deployment still exists — operator must undeploy first
        if _pgrst_deployment_exists "$deployment_name"; then
            local msg="Cannot purge $app_name: Deployment '$deployment_name' still exists in namespace $PGRST_NAMESPACE. Run './uis undeploy postgrest --app $app_name' first."
            if [[ "$json_output" == true ]]; then
                _configure_error "purge" "$service_id" "$msg"
            fi
            log_error "$msg"
            return 1
        fi

        # Resolve the target database. The schema-level grants
        # (USAGE on schema, SELECT on tables, default privileges) live in the
        # database the operator passed to `configure --database`, which may not
        # be the default `app_name`. The existing secret holds the authoritative
        # connection string — read the database name from there if present.
        local target_db="$database_name"
        if _pgrst_secret_exists "$secret_name"; then
            local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
            local existing_uri parsed_db
            existing_uri=$(kubectl get secret "$secret_name" -n "$PGRST_NAMESPACE" \
                --kubeconfig="$kubeconf" \
                -o jsonpath='{.data.PGRST_DB_URI}' 2>/dev/null | base64 -d)
            if [[ -n "$existing_uri" ]]; then
                # postgresql://user:pass@host:port/dbname[?...] → strip everything before the last '/' and any query string
                parsed_db="${existing_uri##*/}"
                parsed_db="${parsed_db%%\?*}"
                [[ -n "$parsed_db" ]] && target_db="$parsed_db"
            fi
        fi

        # DROP OWNED BY clears schema-level privileges (and default privilege
        # entries where the role is grantee) before DROP ROLE. Without this,
        # web_anon's GRANT USAGE on the schema blocks DROP ROLE. The DO block
        # makes both pairs idempotent — re-purge after a partial cleanup
        # succeeds rather than erroring on a missing role.
        echo "Dropping Postgres roles for app '$app_name' in database '$target_db'..." >&2
        local drop_sql drop_result rc=0
        drop_sql=$(cat <<EOF
DO \$\$
DECLARE
    role_exists boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$authenticator_role') INTO role_exists;
    IF role_exists THEN
        EXECUTE format('DROP OWNED BY %I CASCADE', '$authenticator_role');
        EXECUTE format('DROP ROLE %I', '$authenticator_role');
    END IF;
    SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$web_anon_role') INTO role_exists;
    IF role_exists THEN
        EXECUTE format('DROP OWNED BY %I CASCADE', '$web_anon_role');
        EXECUTE format('DROP ROLE %I', '$web_anon_role');
    END IF;
END
\$\$;
EOF
)
        # `|| rc=$?` to capture exit without tripping caller's `set -e`.
        drop_result=$(_pgrst_exec_db "$drop_sql" "$admin_pass" "$target_db") || rc=$?
        if [[ $rc -ne 0 ]]; then
            if [[ "$json_output" == true ]]; then
                _configure_error "purge" "$service_id" "Failed to drop roles for '$app_name' in '$target_db' (psql exit $rc): $drop_result"
            fi
            log_error "Failed to drop roles for '$app_name' in '$target_db' (psql exit $rc):"
            log_error "$drop_result"
            return 1
        fi

        echo "Removing secret '$secret_name' from namespace $PGRST_NAMESPACE..." >&2
        _pgrst_delete_secret "$secret_name"

        if [[ "$json_output" == true ]]; then
            cat <<EOF
{"status":"purged","service":"postgrest","app":"$app_name","database":"$target_db","roles_dropped":["$authenticator_role","$web_anon_role"],"secret_removed":"$secret_name"}
EOF
        else
            echo ""
            echo "Purged PostgREST configuration for '$app_name':"
            echo "  Database:        $target_db"
            echo "  Dropped roles:   $authenticator_role, $web_anon_role"
            echo "  Removed secret:  $PGRST_NAMESPACE/$secret_name"
        fi
        return 0
    fi

    # ---- ROTATE PATH (Decision #17) ----
    # Rotate generates a new password and rewrites the secret. PGRST_DB_SCHEMAS
    # must be preserved across rotate; if the key is missing (PLAN-002-era
    # secret), refuse and direct the operator to run configure first.
    if [[ "$rotate" == "true" ]]; then
        if ! _pgrst_role_exists "$authenticator_role" "$admin_pass"; then
            local msg="Cannot rotate password for $app_name: role '$authenticator_role' does not exist. Run configure without --rotate first to create it."
            if [[ "$json_output" == true ]]; then
                _configure_error "rotate" "$service_id" "$msg"
            fi
            log_error "$msg"
            return 1
        fi

        # Read PGRST_DB_SCHEMAS from existing secret; fail if absent. Rotate
        # is not the upgrade path — operator must run configure with --schemas
        # first to establish the key.
        local existing_schemas
        existing_schemas=$(_pgrst_get_secret_schemas "$secret_name")
        if [[ -z "$existing_schemas" ]]; then
            local msg="PGRST_DB_SCHEMAS not present in secret. Run './uis configure postgrest --app $app_name --schemas <list>' first to establish the schema list, then retry rotate."
            if [[ "$json_output" == true ]]; then
                _configure_error "rotate" "$service_id" "$msg"
            fi
            log_error "$msg"
            return 1
        fi

        echo "WARNING: rotating password for '$authenticator_role' will invalidate the running PostgREST connection pool until the pod is restarted." >&2
        echo "After this completes, run: kubectl rollout restart deployment/$deployment_name -n $PGRST_NAMESPACE" >&2

        local new_password
        new_password=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)

        # `|| rc=$?` so a failing alter doesn't trip the caller's `set -e`.
        local alter_result rc=0
        alter_result=$(_pgrst_exec "ALTER USER $authenticator_role WITH PASSWORD '$new_password'" "$admin_pass" 2>&1) || rc=$?
        if [[ $rc -ne 0 ]]; then
            if [[ "$json_output" == true ]]; then
                _configure_error "rotate" "$service_id" "Failed to rotate password for '$authenticator_role' (psql exit $rc): $alter_result"
            fi
            log_error "Failed to rotate password for '$authenticator_role' (psql exit $rc):"
            log_error "$alter_result"
            return 1
        fi

        # Update the secret with the new password; preserve schemas verbatim.
        local db_uri="postgresql://${authenticator_role}:${new_password}@${PG_CLUSTER_HOST}:${PG_INTERNAL_PORT}/${database_name}"
        _pgrst_ensure_namespace "$PGRST_NAMESPACE"
        _pgrst_create_secret "$secret_name" "$db_uri" "$existing_schemas"

        if [[ "$json_output" == true ]]; then
            cat <<EOF
{"status":"rotated","service":"postgrest","app":"$app_name","namespace":"$PGRST_NAMESPACE","secret":"$secret_name","schemas":"$existing_schemas","next_step":"kubectl rollout restart deployment/$deployment_name -n $PGRST_NAMESPACE"}
EOF
        else
            echo ""
            echo "Rotated password for '$app_name':"
            echo "  Role: $authenticator_role"
            echo "  Secret: $PGRST_NAMESPACE/$secret_name (keys PGRST_DB_URI + PGRST_DB_SCHEMAS)"
            echo "  Schemas: $existing_schemas (preserved)"
            echo "  Next step: kubectl rollout restart deployment/$deployment_name -n $PGRST_NAMESPACE"
        fi
        return 0
    fi

    # ---- DEFAULT PATH (configure with --schemas) ----
    # Implements the State Matrix dispatch from
    # INVESTIGATE-postgrest-multi-schema-reconciliation.md §State Matrix.
    # Five paths: First-time, Reconfigure-preserve-URI,
    # Reconfigure-fresh-password, No-op, Inconsistent.

    echo "Configuring PostgREST for app '$app_name'..." >&2
    echo "  Database: $database_name" >&2
    echo "  Schemas:  $schemas" >&2
    echo "  URL prefix: $url_prefix" >&2

    # ---- PHASE 1: pre-flight validation (R4) ----

    # R4 string-level: normalize, regex, dedup, empty-check.
    local normalized_schemas
    normalized_schemas=$(_pgrst_normalize_schemas "$schemas") || {
        # error already printed to stderr by the helper
        if [[ "$json_output" == true ]]; then
            _configure_error "usage" "$service_id" "Invalid --schemas value '$schemas' (see stderr for details)."
        fi
        return 1
    }
    schemas="$normalized_schemas"

    # Database existence precheck (otherwise psql exits 2 with a confusing
    # "could not connect" inside _pgrst_exec_db). Belt-and-suspenders before
    # the per-schema existence check, which assumes the database exists.
    local db_check_rc=0
    local db_check
    db_check=$(_pgrst_exec "SELECT 1 FROM pg_database WHERE datname='$database_name'" "$admin_pass") || db_check_rc=$?
    if [[ $db_check_rc -ne 0 || "$db_check" != "1" ]]; then
        local msg="Database '$database_name' does not exist in the cluster's PostgreSQL. Create it first (typically via the consuming app's migration / bootstrap script), then retry: ./uis configure postgrest --app $app_name --database $database_name --schemas $schemas"
        if [[ "$json_output" == true ]]; then
            _configure_error "create_resources" "$service_id" "$msg"
        fi
        log_error "$msg"
        return 1
    fi

    # R4 step 4: per-schema existence check. Fail-loud naming the offender.
    if ! _pgrst_check_schemas_exist "$schemas" "$admin_pass" "$database_name"; then
        # error printed by helper
        if [[ "$json_output" == true ]]; then
            _configure_error "usage" "$service_id" "One or more schemas in '$schemas' do not exist in database '$database_name'."
        fi
        return 1
    fi

    # ---- PHASE 2: state inspection (place ourselves on the State Matrix) ----

    local web_anon_exists=false
    local auth_exists=false
    local secret_exists=false
    local existing_schemas=""
    local existing_uri=""

    _pgrst_role_exists "$web_anon_role" "$admin_pass" && web_anon_exists=true
    _pgrst_role_exists "$authenticator_role" "$admin_pass" && auth_exists=true
    _pgrst_secret_exists "$secret_name" && secret_exists=true

    if [[ "$secret_exists" == true ]]; then
        existing_schemas=$(_pgrst_get_secret_schemas "$secret_name")
        existing_uri=$(_pgrst_get_secret_uri "$secret_name")
    fi

    # ---- PHASE 3: reject inconsistent states (Partial roles, Orphan secret) ----

    if [[ "$web_anon_exists" != "$auth_exists" ]]; then
        local existing_role missing_role
        if [[ "$web_anon_exists" == true ]]; then
            existing_role="$web_anon_role"; missing_role="$authenticator_role"
        else
            existing_role="$authenticator_role"; missing_role="$web_anon_role"
        fi
        local msg="Inconsistent role state for app '$app_name': role '$existing_role' exists but '$missing_role' does not. Run './uis configure postgrest --app $app_name --purge' to clear and retry."
        if [[ "$json_output" == true ]]; then
            _configure_error "inconsistent_state" "$service_id" "$msg"
        fi
        log_error "$msg"
        return 1
    fi

    # At this point web_anon_exists == auth_exists. If neither exists but the
    # secret does, we have an orphan secret (roles dropped externally).
    if [[ "$secret_exists" == true && "$web_anon_exists" == false ]]; then
        local msg="Orphan secret: '$secret_name' exists but neither role exists. Run './uis configure postgrest --app $app_name --purge' to clear and retry."
        if [[ "$json_output" == true ]]; then
            _configure_error "inconsistent_state" "$service_id" "$msg"
        fi
        log_error "$msg"
        return 1
    fi

    # ---- PHASE 4: dispatch to a State Matrix path ----

    local path
    if [[ "$web_anon_exists" == true ]]; then
        # Both roles exist.
        if [[ "$secret_exists" == true ]]; then
            if [[ -n "$existing_schemas" && "$existing_schemas" == "$schemas" ]]; then
                path="no-op"
            else
                path="reconfigure-preserve-uri"
            fi
        else
            path="reconfigure-fresh-password"
        fi
    else
        # Neither role exists, no secret (orphan-secret case rejected above).
        path="first-time"
    fi

    # ---- PHASE 5: no-op short-circuit ----
    if [[ "$path" == "no-op" ]]; then
        echo "PostgREST already configured for '$app_name' with schemas '$schemas' — nothing to do." >&2
        if [[ "$json_output" == true ]]; then
            cat <<EOF
{"status":"already_configured","service":"postgrest","app":"$app_name","namespace":"$PGRST_NAMESPACE","secret":"$secret_name","schemas":"$schemas","public_url_prefix":"$url_prefix","next_step":"./uis deploy postgrest --app $app_name"}
EOF
        else
            echo ""
            echo "PostgREST already configured for '$app_name' (schemas: $schemas). To proceed:"
            echo "  ./uis deploy postgrest --app $app_name"
            echo ""
            echo "To rotate the password: ./uis configure postgrest --app $app_name --rotate"
            echo "To remove configuration: ./uis configure postgrest --app $app_name --purge"
        fi
        return 0
    fi

    # ---- PHASE 6: build SQL for the chosen path ----

    # Per-schema GRANT block (USAGE + SELECT on existing tables + DEFAULT
    # PRIVILEGES for future tables) — used by all three SQL paths.
    local grant_sql
    grant_sql=$(_pgrst_build_grant_sql "$schemas" "$web_anon_role")

    # Decide password handling per path. For Reconfigure-preserve-URI the
    # password is unchanged; we don't touch the role's stored password and we
    # round-trip the existing PGRST_DB_URI verbatim into the secret.
    local app_password=""
    local sql_block=""
    case "$path" in
        first-time)
            app_password=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
            sql_block=$(cat <<EOF
BEGIN;
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$web_anon_role') THEN
        CREATE ROLE $web_anon_role NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$authenticator_role') THEN
        CREATE ROLE $authenticator_role LOGIN PASSWORD '$app_password' NOINHERIT;
    END IF;
END
\$\$;
GRANT $web_anon_role TO $authenticator_role;
$grant_sql
COMMIT;
EOF
)
            ;;
        reconfigure-preserve-uri)
            sql_block=$(cat <<EOF
BEGIN;
DROP OWNED BY $web_anon_role;
$grant_sql
COMMIT;
EOF
)
            ;;
        reconfigure-fresh-password)
            app_password=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
            sql_block=$(cat <<EOF
BEGIN;
ALTER USER $authenticator_role WITH PASSWORD '$app_password';
DROP OWNED BY $web_anon_role;
$grant_sql
COMMIT;
EOF
)
            ;;
    esac

    echo "Applying SQL for path '$path' (database: $database_name)..." >&2
    local sql_result rc=0
    sql_result=$(_pgrst_exec_db "$sql_block" "$admin_pass" "$database_name") || rc=$?
    if [[ $rc -ne 0 ]]; then
        local hint="psql exit $rc: $sql_result"
        if [[ $rc -eq 2 ]]; then
            hint+=$'\n'"Hint: psql exit 2 means it could not connect to database '$database_name'."
        fi
        if [[ "$json_output" == true ]]; then
            _configure_error "create_resources" "$service_id" "SQL transaction failed for path '$path' in '$database_name'. $hint"
        fi
        log_error "SQL transaction failed for path '$path' in '$database_name' (psql exit $rc):"
        log_error "$sql_result"
        return 1
    fi

    # ---- PHASE 7: write the secret ----

    _pgrst_ensure_namespace "$PGRST_NAMESPACE"

    local db_uri
    if [[ "$path" == "reconfigure-preserve-uri" ]]; then
        # Preserve the existing PGRST_DB_URI verbatim (password unchanged).
        # If the secret has no PGRST_DB_URI key (shouldn't happen — secret
        # exists per state inspection — but defensive): rebuild from a fresh
        # password as a last resort.
        if [[ -n "$existing_uri" ]]; then
            db_uri="$existing_uri"
        else
            log_warn "Existing secret '$secret_name' has no PGRST_DB_URI key; generating a fresh password (recovery path)."
            app_password=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
            db_uri="postgresql://${authenticator_role}:${app_password}@${PG_CLUSTER_HOST}:${PG_INTERNAL_PORT}/${database_name}"
            # Apply the new password to the role since we're now diverging
            # from the on-disk URI.
            _pgrst_exec "ALTER USER $authenticator_role WITH PASSWORD '$app_password'" "$admin_pass" >/dev/null 2>&1 || true
        fi
    else
        # First-time and Reconfigure-fresh-password both have a fresh password.
        db_uri="postgresql://${authenticator_role}:${app_password}@${PG_CLUSTER_HOST}:${PG_INTERNAL_PORT}/${database_name}"
    fi

    echo "Writing secret '$secret_name' in namespace $PGRST_NAMESPACE..." >&2
    _pgrst_create_secret "$secret_name" "$db_uri" "$schemas"

    # ---- PHASE 8: NOTIFY pgrst, 'reload schema' ----

    _pgrst_notify_reload "$admin_pass" "$database_name"

    # ---- PHASE 9: output ----

    if [[ "$json_output" == true ]]; then
        cat <<EOF
{"status":"ok","service":"postgrest","app":"$app_name","namespace":"$PGRST_NAMESPACE","secret":"$secret_name","schemas":"$schemas","path":"$path","in_cluster_url":"http://$deployment_name.$PGRST_NAMESPACE.svc.cluster.local:3000","public_url_prefix":"$url_prefix","next_step":"./uis deploy postgrest --app $app_name"}
EOF
    else
        echo ""
        echo "PostgREST configured for '$app_name' (path: $path):"
        echo "  Database:        $database_name"
        echo "  Schemas:         $schemas"
        echo "  URL prefix:      $url_prefix"
        case "$path" in
            first-time)
                echo "  Roles created:   $web_anon_role (NOLOGIN), $authenticator_role (LOGIN NOINHERIT)"
                ;;
            reconfigure-preserve-uri)
                echo "  Roles:           kept (password preserved)"
                ;;
            reconfigure-fresh-password)
                echo "  Roles:           kept; password rotated (secret was missing)"
                ;;
        esac
        echo "  Secret:          $PGRST_NAMESPACE/$secret_name (keys PGRST_DB_URI + PGRST_DB_SCHEMAS)"
        echo ""
        echo "Next step:"
        echo "  ./uis deploy postgrest --app $app_name"
    fi
    return 0
}
