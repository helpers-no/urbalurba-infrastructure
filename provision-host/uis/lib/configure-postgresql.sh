#!/bin/bash
# configure-postgresql.sh — PostgreSQL handler for uis configure
#
# Creates a per-app database and user in the running PostgreSQL instance.
# Returns connection details as JSON.
#
# See: helpers-no/dev-templates INVESTIGATE-unified-template-system.md (2UIS, 7UIS)
# See: PLAN-001-uis-configure-expose.md Phase 3

# PostgreSQL connection details (inside the cluster)

# See pg-connection.sh — ALWAYS pass -h. The local socket does not exist on the
# proxied topology. Defined defensively here so this lib works even when sourced
# outside uis-cli.sh.
PG_PSQL_HOST="${PG_PSQL_HOST:-127.0.0.1}"

PG_ADMIN_USER="postgres"
PG_K8S_SVC="postgresql"
PG_NAMESPACE="default"
PG_INTERNAL_PORT=5432
PG_CLUSTER_HOST="postgresql.default.svc.cluster.local"

# Get the admin password from urbalurba-secrets
_pg_get_admin_password() {
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    kubectl get secret urbalurba-secrets \
        -n "$PG_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -o jsonpath='{.data.PGPASSWORD}' 2>/dev/null | base64 -d
}

# Find the postgresql pod name
_pg_get_pod() {
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    kubectl get pods -n "$PG_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -l app.kubernetes.io/name=postgresql \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Run psql command inside the postgresql pod
_pg_exec() {
    local sql="$1"
    local admin_pass="$2"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    local pod
    pod=$(_pg_get_pod)

    if [[ -z "$pod" ]]; then
        return 1
    fi

    kubectl exec "$pod" \
        -n "$PG_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -- env PGPASSWORD="$admin_pass" psql -h "$PG_PSQL_HOST" -U "$PG_ADMIN_USER" -t -A -c "$sql"
}

# Run psql with a specific database
_pg_exec_db() {
    local sql="$1"
    local database="$2"
    local user="$3"
    local pass="$4"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    local pod
    pod=$(_pg_get_pod)

    kubectl exec "$pod" \
        -n "$PG_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -- env PGPASSWORD="$pass" psql -h "$PG_PSQL_HOST" -U "$user" -d "$database" -t -A -c "$sql"
}

# Apply init file via stdin to a database
_pg_apply_init_file() {
    local database="$1"
    local user="$2"
    local pass="$3"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    local pod
    pod=$(_pg_get_pod)

    # Read init file from stdin, pipe to psql with ON_ERROR_STOP
    kubectl exec -i "$pod" \
        -n "$PG_NAMESPACE" \
        --kubeconfig="$kubeconf" \
        -- env PGPASSWORD="$pass" psql -h "$PG_PSQL_HOST" -U "$user" -d "$database" \
           --set ON_ERROR_STOP=on -f - 2>&1
}

# Check if a database exists
_pg_database_exists() {
    local db_name="$1"
    local admin_pass="$2"
    local result
    result=$(_pg_exec "SELECT 1 FROM pg_database WHERE datname='$db_name'" "$admin_pass")
    [[ "$result" == "1" ]]
}

# Check if a user exists
_pg_user_exists() {
    local username="$1"
    local admin_pass="$2"
    local result
    result=$(_pg_exec "SELECT 1 FROM pg_roles WHERE rolname='$username'" "$admin_pass")
    [[ "$result" == "1" ]]
}

# Ensure a Kubernetes namespace exists (idempotent)
_pg_ensure_namespace() {
    local ns="$1"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"
    kubectl create namespace "$ns" \
        --kubeconfig="$kubeconf" \
        --dry-run=client -o yaml 2>/dev/null \
        | kubectl apply --kubeconfig="$kubeconf" -f - >/dev/null 2>&1
}

# Create or update a K8s Secret containing DATABASE_URL (idempotent)
_pg_create_secret() {
    local ns="$1"
    local secret_name="$2"
    local database_url="$3"
    local kubeconf="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"

    kubectl create secret generic "$secret_name" \
        --namespace="$ns" \
        --from-literal=DATABASE_URL="$database_url" \
        --kubeconfig="$kubeconf" \
        --dry-run=client -o yaml 2>/dev/null \
        | kubectl apply --kubeconfig="$kubeconf" -f - >/dev/null 2>&1
}

# Build JSON fragment for namespace/secret fields (empty if not requested)
_pg_secret_json_fragment() {
    local namespace="$1"
    local secret_name="$2"
    if [[ -n "$namespace" && -n "$secret_name" ]]; then
        echo ",\"secret_name\":\"$secret_name\",\"secret_namespace\":\"$namespace\",\"env_var\":\"DATABASE_URL\""
    fi
}

# Main handler — called by configure.sh
configure_service() {
    local service_id="$1"
    local app_name="$2"
    local database_name="$3"
    local init_file="$4"
    local json_output="$5"
    local namespace="${6:-}"
    local secret_name_prefix="${7:-}"

    # Compute secret name once
    local secret_name=""
    if [[ -n "$secret_name_prefix" ]]; then
        secret_name="${secret_name_prefix}-db"
    fi

    # Derive database name if not provided
    if [[ -z "$database_name" ]]; then
        # Convert app-name to app_name_db
        database_name=$(echo "${app_name}" | tr '-' '_')"_db"
    fi

    # Derive username from app name (convert hyphens to underscores)
    local username
    username=$(echo "${app_name}" | tr '-' '_')

    # 🔴 Validate both identifiers BEFORE anything runs as the database admin.
    #
    # These are interpolated into SQL executed as the postgres superuser. The
    # derived defaults are safe by construction, but --database is operator- and
    # template-supplied: `{{ params.app_name }}` reaches here verbatim. A name
    # containing a double quote would break out of the quoting added below, and
    # this is the one command in UIS where that matters most.
    local _ident
    for _ident in "$app_name" "$database_name" "$username"; do
        if [[ ! "$_ident" =~ ^[A-Za-z0-9_-]+$ ]]; then
            if [[ "$json_output" == true ]]; then
                _configure_error "usage" "$service_id" "Invalid identifier '$_ident': letters, digits, underscore and hyphen only"
            fi
            log_error "Invalid identifier '$_ident'."
            echo "  Letters, digits, underscore and hyphen only — these become SQL" >&2
            echo "  identifiers and a Kubernetes Secret name." >&2
            return 1
        fi
    done

    echo "Configuring PostgreSQL for app '$app_name'..." >&2

    # Get admin password
    local admin_pass
    admin_pass=$(_pg_get_admin_password)
    if [[ -z "$admin_pass" ]]; then
        if [[ "$json_output" == true ]]; then
            _configure_error "create_resources" "$service_id" "Could not read PGPASSWORD from urbalurba-secrets. Run: uis secrets apply"
        fi
        log_error "Could not read PGPASSWORD from urbalurba-secrets"
        return 1
    fi

    # Get the expose port (used in both ok and already_configured responses)
    local expose_port
    expose_port=$(_get_expose_port "$service_id" 2>/dev/null || echo "35432")

    # Check idempotency — if database already exists, reset password and return credentials
    # (DCT needs full connection details on already_configured — see gap from DCT round 1)
    if _pg_database_exists "$database_name" "$admin_pass"; then
        echo "Database '$database_name' already exists — resetting password." >&2

        # Generate a fresh password and reset it (we don't store per-app passwords)
        local app_password
        app_password=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)

        local alter_result
        alter_result=$(_pg_exec "ALTER USER \"$username\" WITH PASSWORD '$app_password'" "$admin_pass" 2>&1)
        if [[ $? -ne 0 ]]; then
            if [[ "$json_output" == true ]]; then
                _configure_error "create_resources" "$service_id" "Failed to reset password for user '$username': $alter_result"
            fi
            log_error "Failed to reset password for user '$username'"
            return 1
        fi

        # Auto-expose if not already exposed
        if type expose_service &>/dev/null; then
            if ! _is_exposed "$service_id" 2>/dev/null; then
                expose_service "$service_id" >&2 || true
            fi
        fi

        # Build cluster URL with the new password
        local cluster_url="postgresql://$username:$app_password@$PG_CLUSTER_HOST:$PG_INTERNAL_PORT/$database_name"

        # If --namespace was passed, ensure namespace exists and update the secret with the new password
        if [[ -n "$namespace" ]]; then
            echo "Ensuring namespace '$namespace' exists..." >&2
            _pg_ensure_namespace "$namespace"
            echo "Updating secret '$secret_name' in namespace '$namespace'..." >&2
            _pg_create_secret "$namespace" "$secret_name" "$cluster_url"
        fi

        # 🔴 Apply the init file HERE TOO. It used to be applied only on the
        # create path, several hundred lines below a `return 0` this branch
        # reaches first — so on an existing database the init SQL was read from
        # stdin and silently discarded.
        #
        # That is the install-time guarantee the whole application-catalogue
        # design rests on: `template install` prints
        #   `configure postgresql ... --init-file -   (stdin: 35 lines)`
        # and then, on any database that already existed, applied none of them
        # and exited 0. The second run of an install does something materially
        # different from the first and reports the same success.
        #
        # ⚠️ Re-applying is safe BY CONTRACT, not by luck: an `init:` must
        # satisfy "the schema after one application equals the schema after
        # two" (atlas, urb-agents#362 — measured, and their migrations did not
        # have that property until they fixed it). That requirement exists
        # precisely so this path can exist.
        local init_applied=false
        if [[ "$init_file" == "-" ]]; then
            echo "Applying init file from stdin (database already existed)..." >&2
            local re_init_result re_init_exit
            re_init_result=$(_pg_apply_init_file "$database_name" "$username" "$app_password") && re_init_exit=0 || re_init_exit=$?
            if [[ $re_init_exit -ne 0 ]]; then
                echo "Init file failed:" >&2
                echo "$re_init_result" >&2
                # ⚠️ NO ROLLBACK HERE, deliberately. The create path drops the
                # database it just made; this database predates the command and
                # may hold data nothing can reconstruct. Refuse loudly and leave
                # it alone — dropping someone else's data to tidy up a failed
                # re-run is not a trade this command gets to make.
                if [[ "$json_output" == true ]]; then
                    local re_escaped
                    re_escaped=$(echo "$re_init_result" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip())[1:-1])' 2>/dev/null || echo "$re_init_result" | tr '\n' ' ' | sed 's/"/\\"/g; s/\\/\\\\/g')
                    cat <<EOF
{"status":"error","phase":"init_file","service":"postgresql","detail":"$re_escaped","database_preserved":true}
EOF
                    exit 1
                fi
                log_error "Init file failed on an existing database. The database was NOT dropped."
                return 1
            fi
            echo "Init file applied successfully." >&2
            init_applied=true
        fi

        # ⚠️ The password was just rotated and UIS does not store it, so any
        # workload holding the OLD one keeps failing until it re-reads the
        # Secret. Env-var consumers re-read only on pod restart — which is the
        # normal case for a Dagster code location. Say so; a silent credential
        # rotation under a running application is the kind of thing that gets
        # diagnosed as a network fault.
        log_warn "Password for '$username' was rotated. Workloads holding the old credential"
        echo "         will fail until their pods restart and re-read '$secret_name'." >&2

        local secret_fragment
        secret_fragment=$(_pg_secret_json_fragment "$namespace" "$secret_name")

        if [[ "$json_output" == true ]]; then
            cat <<EOF
{"status":"already_configured","service":"postgresql","local":{"host":"host.docker.internal","port":$expose_port,"database_url":"postgresql://$username:$app_password@host.docker.internal:$expose_port/$database_name"},"cluster":{"host":"$PG_CLUSTER_HOST","port":$PG_INTERNAL_PORT,"database_url":"$cluster_url"},"database":"$database_name","username":"$username","password":"$app_password"$secret_fragment,"init_applied":$init_applied,"message":"Database and user already existed; password was reset and any init file was re-applied. Store these credentials — old ones are invalidated."}
EOF
            return 0
        fi
        log_info "Database '$database_name' already existed; password reset for user '$username'."
        return 0
    fi

    # Generate per-app password (2UIS — UIS does not store this)
    local app_password
    app_password=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)

    echo "Creating user '$username'..." >&2

    # Create user. Track whether WE made it: the rollback below must not drop a
    # role that predates this command.
    local create_user_result user_was_created=false
    if ! _pg_user_exists "$username" "$admin_pass"; then
        user_was_created=true
    fi
    create_user_result=$(_pg_exec "CREATE USER \"$username\" WITH PASSWORD '$app_password'" "$admin_pass" 2>&1)
    if [[ $? -ne 0 ]] && ! _pg_user_exists "$username" "$admin_pass"; then
        if [[ "$json_output" == true ]]; then
            _configure_error "create_resources" "$service_id" "Failed to create user '$username': $create_user_result"
        fi
        log_error "Failed to create user '$username'"
        return 1
    fi

    echo "Creating database '$database_name'..." >&2

    # Create database
    local create_db_result
    # ⚠️ QUOTE the database identifier. A hyphen is legal in a quoted identifier
    # and a syntax error in an unquoted one, and the username is derived with
    # `-` -> `_` while the database name is not — so `--param app_name=atlas-t`
    # produced `CREATE DATABASE atlas-t OWNER atlas_t` and failed at the hyphen,
    # AFTER creating the role, which was then left orphaned (imac,
    # urb-agents#481, following an instruction of mine that named exactly that
    # parameter). All-lowercase unquoted and quoted identifiers are the same
    # object, so nothing existing changes.
    create_db_result=$(_pg_exec "CREATE DATABASE \"$database_name\" OWNER \"$username\"" "$admin_pass" 2>&1)
    if [[ $? -ne 0 ]]; then
        # Roll back the role we just created. Leaving it behind made the next
        # attempt a two-step manual cleanup for the tester rather than a re-run.
        if [[ "$user_was_created" == true ]]; then
            echo "Rolling back: dropping user '$username' created moments ago..." >&2
            _pg_exec "DROP USER IF EXISTS \"$username\"" "$admin_pass" >/dev/null 2>&1
        fi
        if [[ "$json_output" == true ]]; then
            _configure_error "create_resources" "$service_id" "Failed to create database '$database_name': $create_db_result"
        fi
        log_error "Failed to create database '$database_name'"
        return 1
    fi

    # Grant privileges
    _pg_exec "GRANT ALL PRIVILEGES ON DATABASE \"$database_name\" TO \"$username\"" "$admin_pass" >/dev/null 2>&1

    echo "Database '$database_name' created with user '$username'." >&2

    # Apply init file if provided via stdin
    if [[ "$init_file" == "-" ]]; then
        echo "Applying init file from stdin..." >&2
        # Guard against set -e: capture both output and exit code without triggering exit
        local init_result init_exit
        init_result=$(_pg_apply_init_file "$database_name" "$username" "$app_password") && init_exit=0 || init_exit=$?
        if [[ $init_exit -ne 0 ]]; then
            # Show the real psql error on stderr so users can see what went wrong
            echo "Init file failed:" >&2
            echo "$init_result" >&2

            # Roll back: drop the database and user we just created
            echo "Rolling back: dropping database '$database_name' and user '$username'..." >&2
            _pg_exec "DROP DATABASE IF EXISTS \"$database_name\"" "$admin_pass" >/dev/null 2>&1
            _pg_exec "DROP USER IF EXISTS \"$username\"" "$admin_pass" >/dev/null 2>&1

            if [[ "$json_output" == true ]]; then
                # Build JSON detail from the full psql error output
                local escaped_detail
                escaped_detail=$(echo "$init_result" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip())[1:-1])' 2>/dev/null || echo "$init_result" | tr '\n' ' ' | sed 's/"/\\"/g; s/\\/\\\\/g')
                # Emit JSON error on STDOUT (DCT parses stdout)
                cat <<EOF
{"status":"error","phase":"init_file","service":"postgresql","detail":"$escaped_detail"}
EOF
                exit 1
            fi
            log_error "Init file failed and rollback performed"
            return 1
        fi
        echo "Init file applied successfully." >&2
    fi

    # Auto-expose if not already exposed (6UIS)
    if type expose_service &>/dev/null; then
        if ! _is_exposed "$service_id" 2>/dev/null; then
            echo "Auto-exposing $service_id..." >&2
            expose_service "$service_id" >&2 || true
        fi
    fi

    # Build cluster URL (used for both JSON and secret)
    local cluster_url="postgresql://$username:$app_password@$PG_CLUSTER_HOST:$PG_INTERNAL_PORT/$database_name"

    # If --namespace was passed, ensure namespace exists and create the secret
    if [[ -n "$namespace" ]]; then
        echo "Ensuring namespace '$namespace' exists..." >&2
        _pg_ensure_namespace "$namespace"
        echo "Creating secret '$secret_name' in namespace '$namespace'..." >&2
        _pg_create_secret "$namespace" "$secret_name" "$cluster_url"
    fi

    local secret_fragment
    secret_fragment=$(_pg_secret_json_fragment "$namespace" "$secret_name")

    # Return JSON on stdout (Decision #13)
    if [[ "$json_output" == true ]]; then
        cat <<EOF
{"status":"ok","service":"postgresql","local":{"host":"host.docker.internal","port":$expose_port,"database_url":"postgresql://$username:$app_password@host.docker.internal:$expose_port/$database_name"},"cluster":{"host":"$PG_CLUSTER_HOST","port":$PG_INTERNAL_PORT,"database_url":"$cluster_url"},"database":"$database_name","username":"$username","password":"$app_password"$secret_fragment}
EOF
    else
        echo ""
        echo "PostgreSQL configured for '$app_name':"
        echo "  Database: $database_name"
        echo "  Username: $username"
        echo "  Password: $app_password"
        echo ""
        echo "  Local:   postgresql://$username:$app_password@host.docker.internal:$expose_port/$database_name"
        echo "  Cluster: $cluster_url"
        if [[ -n "$namespace" ]]; then
            echo ""
            echo "  Secret:  $secret_name (namespace: $namespace, key: DATABASE_URL)"
        fi
    fi
}
