# Ansible playbook templates (Jinja, rendered per-instance)

This directory holds Jinja2 templates that are rendered to Kubernetes YAML at
playbook-execution time. It is **distinct from** `manifests/` — that directory
holds static, single-instance YAML applied directly via
`kubernetes.core.k8s: src: ...`. This directory holds per-instance templates
applied via `kubernetes.core.k8s: definition: "{{ lookup('template', ...) }}"`.

## When to use

Templates here are the right home for a service that ships **per-app
instances** (a "multi-instance" service in UIS terminology). Each call to
`./uis configure <svc> --app <name>` followed by `./uis deploy <svc> --app
<name>` renders these templates with the per-app extra-vars and applies the
result. Template-time substitution avoids having N nearly-identical static
manifests in the `manifests/` tree.

If a service has **one** instance per cluster (most existing UIS services),
keep the static YAML in `manifests/<NNN>-<service>-*.yaml` and reference it
via `src:` in the setup playbook. There is no need to introduce a Jinja
template for the single-instance case.

### Third case: single-instance, but parametrised per installation

There is one more reason a template belongs here, added after the fact because
the first example did not fit either category above: a service that has **one
instance per cluster** but whose manifest depends on **where that installation
put it**.

The external-service proxies are the case. `040-postgresql-external-proxy.yml.j2`
renders a stand-in Deployment + Service that forwards to a database living
outside the cluster, so the address and port differ per installation while the
object is otherwise fixed. It cannot be static YAML (the address varies) and it
is not multi-instance (there is exactly one).

Name these `<NNN>-<service>-external-proxy.yml.j2` and parametrise **only** what
genuinely varies between installations — address, port, namespace. Anything else
that differs between two hand-written examples is accidental variation and should
be removed rather than templated.

## File naming

`<NNN>-<service>-<role>.yml.j2` — same numeric prefix the static manifests use,
matching the service number in `service-<id>.sh`. Example:

```
088-postgrest-config.yml.j2          # Deployment + Service for one PostgREST app
088-postgrest-ingressroute.yml.j2    # Traefik IngressRoute for one PostgREST app
```

## Standard extra-vars

Multi-instance services receive their per-app context via underscore-prefixed
extra-vars (matches the existing `_target` convention in
[`contributors/rules/provisioning.md`](../../../website/docs/contributors/rules/provisioning.md)):

| Var | Meaning | Example |
|---|---|---|
| `_app_name` | Per-app instance name (k8s-safe) | `atlas` |
| `_url_prefix` | First label of the per-app hostname | `api-atlas` |
| `_schema` | Postgres schema PostgREST should expose | `api_v1` |

Service-specific templates may add their own extra-vars; document them at the
top of the corresponding setup playbook.

## How to apply rendered templates from a playbook

```yaml
- name: Apply per-app config (Deployment + Service)
  kubernetes.core.k8s:
    state: present
    kubeconfig: "{{ merged_kubeconf_file }}"
    definition: "{{ lookup('template', 'templates/088-postgrest-config.yml.j2') | from_yaml_all | list }}"
```

`from_yaml_all | list` is needed when a single template emits multiple YAML
documents separated by `---` (e.g. a Deployment and a Service in one file).
For a single-document template, `lookup('template', ...) | from_yaml` is
sufficient.

## Why this convention

PostgREST (PLAN-002) is the first UIS service to require per-instance
manifest rendering. The convention is documented here and in
[`contributors/guides/adding-a-service.md`](../../../website/docs/contributors/guides/adding-a-service.md)
so future multi-instance services follow the same pattern. See
[`INVESTIGATE-postgrest.md` Decision #21](../../../website/docs/ai-developer/plans/backlog/INVESTIGATE-postgrest.md)
for the rationale.
