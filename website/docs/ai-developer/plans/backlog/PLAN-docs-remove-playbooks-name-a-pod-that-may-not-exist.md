---
title: "Remove playbooks tell operators to exec into a pod that may not exist"
status: backlog
type: PLAN
area: docs
severity: low
created: 2026-08-25
---

# Remove playbooks tell operators to exec into a pod that may not exist

## The observation

Six remove playbooks print a manual cleanup command naming `postgresql-0`:

```
kubectl exec -n default postgresql-0 -- psql -U postgres -c "DROP DATABASE openwebui;"
```

`ansible/playbooks/200-remove-open-webui.yml`, `210-remove-litellm.yml`,
`320-remove-unity-catalog.yml`, `340-remove-openmetadata.yml`,
`360-remove-dagster.yml`, `620-remove-nextcloud.yml`,
`650-remove-backstage.yml`, and a troubleshooting line in
`340-test-openmetadata.yml`.

`postgresql-0` is a **StatefulSet artefact of the in-cluster database**. An
installation that declares postgresql in `.uis.extend/external-services.yaml`
gets a transparent proxy instead — a Deployment, so the pod is
`postgresql-<hash>-<hash>` and `postgresql-0` does not exist.

The **production** installation is one of those.

## Severity: low, but not zero

These are printed instructions, not executed code, so nothing breaks
automatically. But an operator following them on the production installation gets

```
Error from server (NotFound): pods "postgresql-0" not found
```

at exactly the moment they are cleaning up after removing a service — and the
obvious reading of that error is "the database is gone", which is alarming and
wrong.

## The fix

Either print the discovered pod name, or print a command that discovers it:

```bash
kubectl exec -n default \
  $(kubectl get pod -n default -l app.kubernetes.io/name=postgresql \
      -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U postgres -c "DROP DATABASE openwebui;"
```

The second is better in printed text: it works on both topologies and teaches
the reader why the name is not fixed.

## How this was found

Preparing dagster for the production installation (PLAN-atlas-asgard-001 Phase
1.2). The same hardcoding was a **functional** defect in two verify playbooks —
`360-test-dagster.yml` and `088-test-postgrest.yml` both `kubectl exec`ed into
`postgresql-0` — which would have failed on any installation proxying to an
external database. Those are fixed; these printed strings are the remainder.

Worth noting the near-miss: postgrest's verify **passed** its independent round
on the test cluster, which runs postgres in-cluster. The same verify would have
failed on the production installation. A green round on one topology says
nothing about the other.

## Related

- The proxy mechanism: `ansible/playbooks/900-external-service-proxy.yml` and
  `templates/040-postgresql-external-proxy.yml.j2`, whose first container
  deliberately carries `psql` so that exec-based playbooks keep working — the
  hardcoded pod name was the one thing that defeated that design
