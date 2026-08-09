#!/usr/bin/env python3
"""Render availability monitors for the services UIS has deployed.

THE GOAL
`uis deploy <service>` should result in that service being monitored, with no
configuration written by the user. They ran a deploy command; they should not
also have to know the service's hostname, health path, or which secret holds its
API key.

Both halves of a monitor are already known:

  HOW to probe  - path, keyword, which secret: ships with the service as
                  services/<category>/probes/<id>.yaml
  WHERE it is   - discovered from the Service / Ingress that `uis deploy` created

⚠️ THE WATCHDOG IS OUTSIDE THE CLUSTER, WHICH CONSTRAINS "WHERE".
Uptime Kuma is deliberately deployed away from the platform it watches - a
monitor inside a cluster cannot report that cluster being down. So a ClusterIP
is useless to it: `litellm.ai.svc.cluster.local` does not resolve from another
machine. Endpoint resolution must yield something reachable from outside, and
when it cannot, that service is reported as unmonitorable rather than silently
skipped. Silence is the failure mode this whole subsystem exists to prevent.
"""

import ipaddress
import json
import os
import subprocess
import sys

# Kubernetes pod CIDR. An Endpoints address outside it means the Service is a
# shim pointing at something beyond the cluster - which, unlike a ClusterIP, an
# external watchdog CAN reach.
POD_CIDRS = ["10.42.0.0/16", "10.244.0.0/16"]

NOTIFICATION_NAME = "uis-alerts"


# Two clusters, deliberately separate.
#   FROM - where the services are.       Read-only. Discovery.
#   TO   - where the watchdog runs.      Written to.
# They are the same cluster for a developer on Rancher Desktop, and different in
# production, because a watchdog inside the cluster it watches cannot report that
# cluster being down.
CTX_FROM = None
CTX_TO = None


def _ctx(ctx):
    return ["--context", ctx] if ctx else []


def kubectl_json(args, ctx=None):
    r = subprocess.run(["kubectl"] + _ctx(ctx) + args + ["-o", "json"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"ERROR: kubectl {' '.join(args)} failed: {r.stderr.strip()}")
    return json.loads(r.stdout)


def is_pod_ip(addr):
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return any(ip in ipaddress.ip_network(c) for c in POD_CIDRS)


def load_cluster():
    """One read of everything endpoint resolution needs."""
    out = {"Service": {}, "Endpoints": {}, "Ingress": [], "IngressRoute": []}
    d = kubectl_json(["get", "svc,endpoints,ingress", "-A"], CTX_FROM)
    for i in d.get("items", []):
        k, md = i["kind"], i["metadata"]
        if k in ("Service", "Endpoints"):
            out[k][(md["namespace"], md["name"])] = i
        elif k == "Ingress":
            out["Ingress"].append(i)
    # IngressRoute is a CRD and may not exist (no Traefik). Not an error.
    try:
        d = kubectl_json(["get", "ingressroute", "-A"], CTX_FROM)
        out["IngressRoute"] = d.get("items", [])
    except SystemExit:
        pass
    return out


def tailnet_hosts(cluster):
    """service -> globally resolvable FQDN, via the tailscale ingress class.

    This is the best possible answer for an external watchdog: a real DNS name
    with a real certificate, reachable from anywhere on the tailnet, with no
    Host-header trickery and no dependence on the cluster's ingress IP.
    """
    found = {}
    for i in cluster["Ingress"]:
        if i["spec"].get("ingressClassName") != "tailscale":
            continue
        lb = i.get("status", {}).get("loadBalancer", {}).get("ingress", [])
        host = lb[0].get("hostname") if lb else None
        if not host:
            continue                      # provisioned but not ready yet
        ns = i["metadata"]["namespace"]
        for r in i["spec"].get("rules", []):
            for p in r.get("http", {}).get("paths", []):
                found[(ns, p["backend"]["service"]["name"])] = host
        db = i["spec"].get("defaultBackend", {}).get("service", {}).get("name")
        if db:
            found[(ns, db)] = host
    return found


def external_endpoint(cluster, ns, name):
    """A shim Service's real address, if it has one.

    A Service whose Endpoints point outside the pod CIDR is a declared
    dependency on something beyond the cluster - an external database, an Ollama
    host on the LAN. The address is right there in the Endpoints object, so the
    watchdog needs nothing from the user.
    """
    e = cluster["Endpoints"].get((ns, name))
    if not e:
        return None
    for subset in e.get("subsets") or []:
        for a in subset.get("addresses") or []:
            if not is_pod_ip(a["ip"]):
                ports = subset.get("ports") or []
                return (a["ip"], ports[0]["port"] if ports else None)
    return None


def watchdog_in_from_cluster(cluster, namespace="monitoring"):
    """Is Uptime Kuma running in the cluster we are rendering for?

    This is THE question that decides how endpoints resolve, and it is answered
    by looking rather than by asking the user to configure it.

    Both topologies are legitimate and UIS supports both:

      Production  - the watchdog runs on a separate machine, because a monitor
                    inside a cluster cannot report that cluster being down.
                    Endpoints must be reachable from outside.

      Development - a developer running UIS on Rancher Desktop has one cluster.
                    Uptime Kuma runs in it, ClusterIP resolves fine, and MORE is
                    monitorable than in production (in-cluster-only services
                    like PostgreSQL included).

    Same command, same probe artifacts, same service definitions - only the
    resolved address differs. That is what keeps dev and prod comparable instead
    of merely similar.
    """
    return (namespace, "uptime-kuma") in cluster["Service"]


def cluster_local(cluster, ns, name):
    """In-cluster DNS name and port for a Service."""
    svc = cluster["Service"].get((ns, name), {})
    ports = svc.get("spec", {}).get("ports") or []
    if not ports:
        return None
    return (f"{name}.{ns}.svc.cluster.local", ports[0].get("port"))


def resolve(cluster, ts, ns, name, in_cluster=False):
    """Where the watchdog can reach this service.""" if False else """Where the watchdog can reach this service.

    Returns (kind, value, why) or (None, None, reason-it-cannot-be-reached).
    Order matters: prefer a real hostname over an IP, and an IP over nothing.
    """
    # In-cluster watchdog: Service DNS is the correct target. It is also the
    # most honest one - it tests the same path other pods use, and it does not
    # depend on ingress being configured at all.
    if in_cluster:
        cl = cluster_local(cluster, ns, name)
        if cl:
            return ("hostport", cl, "in-cluster Service DNS")
    if (ns, name) in ts:
        return ("url", f"https://{ts[(ns, name)]}", "tailnet ingress")
    ext = external_endpoint(cluster, ns, name)
    if ext:
        return ("hostport", ext, "shim Service - external endpoint")
    svc = cluster["Service"].get((ns, name), {})
    stype = svc.get("spec", {}).get("type")
    if stype == "LoadBalancer":
        lb = svc.get("status", {}).get("loadBalancer", {}).get("ingress", [])
        if lb:
            addr = lb[0].get("hostname") or lb[0].get("ip")
            if addr:
                return ("host", addr, "LoadBalancer")
    # ClusterIP with only pod endpoints. Reachable from inside the cluster and
    # nowhere else. Reported, never silently dropped.
    return (None, None,
            "only reachable inside the cluster (ClusterIP). An external "
            "watchdog cannot probe it - expose it, give it a shim, or rely on "
            "the services that depend on it failing their own probes")


def load_probes(services_dir):
    """probe artifacts shipped with services: <category>/probes/<id>.yaml"""
    try:
        import yaml
    except ImportError:
        sys.exit("ERROR: pyyaml not installed")
    out = {}
    if not os.path.isdir(services_dir):
        return out
    for category in sorted(os.listdir(services_dir)):
        pdir = os.path.join(services_dir, category, "probes")
        if not os.path.isdir(pdir):
            continue
        for fn in sorted(os.listdir(pdir)):
            if not fn.endswith((".yaml", ".yml")):
                continue
            with open(os.path.join(pdir, fn)) as fh:
                doc = yaml.safe_load(fh) or {}
            sid = fn.rsplit(".", 1)[0]
            # `service:` names the Kubernetes Service when it differs from the
            # service id - temporal's is temporal-web, authentik's is
            # authentik-server. Without this the probe silently matches nothing,
            # which is the failure mode the whole subsystem exists to avoid.
            out[sid] = {"service": doc.get("service", sid),
                        "probes": doc.get("probes", [])}
    return out


def read_secret_key(key, namespace="monitoring"):
    """A single key out of urbalurba-secrets. Values never live in YAML."""
    import base64
    r = subprocess.run(
        ["kubectl"] + _ctx(CTX_TO) + ["get", "secret", "urbalurba-secrets",
         "-n", namespace, "-o", f"jsonpath={{.data.{key}}}"],
        capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return base64.b64decode(r.stdout.strip()).decode().strip()


def push_token(salt, name):
    """Heartbeat tokens are DERIVED, never random.

    A push token is the URL a job calls. Random tokens mean every rebuild
    reissues every URL, and the old URL then goes quietly silent rather than
    failing loudly - the job keeps exiting 0 while nothing records it. Deriving
    from one salt makes the whole set reproducible: purge and rebuild, and every
    already-wired job keeps working untouched.
    """
    import hashlib
    import hmac
    return hmac.new(salt.encode(), name.encode(), hashlib.sha256).hexdigest()[:32]


def resolve_auth(probe):
    """Resolve `auth: bearer:<SECRET_KEY>` to a header value.

    Returns (headers_json, error). The probe names a KEY in urbalurba-secrets,
    never a value, so definitions stay safe to read and the secret lives in one
    place.

    ⚠️ A missing key must NOT yield an unauthenticated monitor. That produces a
    401, which reads as "the service is down" and pages someone about a
    configuration mistake. Better to refuse to create the monitor and say why.
    """
    spec = probe.get("auth")
    if not spec:
        return None, None
    if ":" not in spec:
        return None, f"unrecognised auth spec '{spec}' (expected bearer:KEY)"
    scheme, key = spec.split(":", 1)
    if scheme != "bearer":
        return None, f"unsupported auth scheme '{scheme}' (only bearer:KEY)"
    val = read_secret_key(key)
    if not val:
        return None, (f"needs secret key '{key}' in urbalurba-secrets. Without "
                      f"it the probe would get 401 and page you about a config "
                      f"mistake, so no monitor was created")
    return json.dumps({"Authorization": f"Bearer {val}"}), None


def render_monitor(name, kind, value, probe):
    """One AutoKuma static-monitor definition.

    ⚠️ Never emits notification_name_list. AutoKuma resolves that only against
    notifications IT manages, and letting it manage the channel makes it rewrite
    the channel every ~5s forever. The setup playbook owns the channel and its
    attachments instead.
    """
    o = {"name": name,
         "_notify": probe.get("notify", True),
         "interval": int(probe.get("interval", 60)),
         "max_retries": int(probe.get("maxretries", 2)),
         "retry_interval": int(probe.get("retry_interval", 60)),
         "active": True}
    ptype = probe.get("type", "http")
    if ptype == "http":
        base = value if kind == "url" else f"http://{value[0]}:{value[1]}"
        o["url"] = base.rstrip("/") + probe.get("path", "/")
        o["type"] = "http"
        if probe.get("keyword"):
            o["type"] = "keyword"      # Kuma models keyword as its own type
            o["keyword"] = probe["keyword"]
        if probe.get("accepted_statuscodes"):
            o["accepted_statuscodes"] = probe["accepted_statuscodes"]
        if probe.get("ignore_tls"):
            o["ignore_tls"] = True
        headers, err = resolve_auth(probe)
        if err:
            return err                 # a string means "cannot build this one"
        if headers:
            o["headers"] = headers
    elif ptype in ("tcp", "port"):
        o["type"] = "port"
        if kind == "hostport":
            o["hostname"], o["port"] = value[0], int(value[1])
        else:
            return None                # a URL is not a TCP target
    elif ptype == "push":
        o["type"] = "push"
    return o


def deployed_services(cluster):
    """Services UIS deployed, as (namespace, name), keyed by service id.

    Matches a probe artifact's filename to a Kubernetes Service of the same
    name. That is the convention `uis deploy` already produces.
    """
    out = {}
    for (ns, name) in cluster["Service"]:
        out.setdefault(name, (ns, name))
    return out


def build(services_dir, extend_file=None, salt=None, watchdog="auto"):
    """Everything that should be monitored, plus everything that cannot be.

    Returns (monitors, skipped). `skipped` is never discarded: a service that
    silently fails to get a monitor is indistinguishable from one that is
    passing, which is the exact trap this subsystem exists to close.
    """
    cluster = load_cluster()
    ts = tailnet_hosts(cluster)
    probes = load_probes(services_dir)
    svc = deployed_services(cluster)

    if watchdog == "auto":
        # Only in-cluster if the watchdog lives in the SAME cluster we are
        # discovering from. Different contexts means production topology, even
        # if a Kuma happens to exist in both.
        in_cluster = (CTX_FROM == CTX_TO) and watchdog_in_from_cluster(cluster)
    else:
        in_cluster = (watchdog == "in-cluster")
    monitors, skipped = [], []
    for sid, spec in sorted(probes.items()):
        plist = spec["probes"]
        target = spec["service"]
        if target not in svc:
            continue                       # service not deployed here
        ns, name = svc[target]
        kind, value, why = resolve(cluster, ts, ns, name, in_cluster)
        if kind is None:
            skipped.append((sid, why))
            continue
        for p in plist:
            mname = sid if p.get("id") in (None, "gateway") else f"{sid}-{p['id']}"
            m = render_monitor(mname, kind, value, p)
            if isinstance(m, str):
                skipped.append((mname, m))
                continue
            if m is None:
                skipped.append((mname, f"probe type {p.get('type')} needs a "
                                       f"host:port, but {sid} resolved to a URL"))
                continue
            monitors.append(m)

    # Targets UIS did NOT deploy: a hypervisor, a NAS, a laptop, a job.
    # Absent on a stock install, and that is the normal case.
    if extend_file and os.path.isfile(extend_file):
        import yaml
        doc = yaml.safe_load(open(extend_file)) or {}
        defaults = doc.get("defaults", {})
        for entry in doc.get("monitors", []):
            m = dict(defaults)
            m.update(entry)
            o = {"name": m["name"], "type": m["type"],
                 "_notify": m.get("notify", True),
                 "interval": int(m.get("interval", 60)),
                 "max_retries": int(m.get("maxretries", 2)),
                 "retry_interval": int(m.get("retry_interval", 60)),
                 "active": True}
            if m["type"] == "http":
                o["url"] = m["url"]
                if m.get("keyword"):
                    o["type"] = "keyword"
                    o["keyword"] = m["keyword"]
                if m.get("ignore_tls"):
                    o["ignore_tls"] = True
                if m.get("accepted_statuscodes"):
                    o["accepted_statuscodes"] = m["accepted_statuscodes"]
            elif m["type"] == "port":
                o["hostname"], o["port"] = m["hostname"], int(m["port"])
            # auth_header_secret names a key in urbalurba-secrets - never a
            # value. Resolved at render time so the secret lives in exactly one
            # place and the definition stays safe to read.
            if m.get("auth_header_secret"):
                hv = read_secret_key(m["auth_header_secret"])
                if hv:
                    o["headers"] = json.dumps({"Authorization": hv})
                else:
                    sys.exit(f"ERROR: {m['name']} references auth_header_secret "
                             f"'{m['auth_header_secret']}' but that key is not in "
                             f"urbalurba-secrets")
            if m["type"] == "push":
                if not salt:
                    sys.exit("ERROR: a push monitor needs uptime-kuma-push-salt "
                             "in urbalurba-secrets - without it the heartbeat "
                             "URL cannot be derived and would change on rebuild")
                o["push_token"] = push_token(salt, m["name"])
            monitors.append(o)

    # ⚠️ Duplicate names would silently overwrite each other: definitions are
    # written as <name>.json, so the second one wins and the first monitor just
    # never exists. Refuse instead. Almost always this means the extend file
    # lists something UIS can now discover on its own.
    seen, dupes = set(), []
    for m in monitors:
        if m["name"] in seen:
            dupes.append(m["name"])
        seen.add(m["name"])
    if dupes:
        sys.exit(
            "ERROR: duplicate monitor names: " + ", ".join(sorted(set(dupes))) +
            "\n\nEach becomes <name>.json, so one would silently replace the "
            "other.\nIf UIS discovered it, remove it from .uis.extend/monitors.yaml "
            "-\nthe extend file is only for targets UIS did NOT deploy.")

    return monitors, skipped, in_cluster


def kuma_sql(namespace, query):
    r = subprocess.run(
        ["kubectl"] + _ctx(CTX_TO) + ["exec", "-n", namespace, "uptime-kuma-0", "--",
         "sqlite3", "-separator", "\x1f", "/app/data/kuma.db", query],
        capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return [l.split("\x1f") for l in r.stdout.strip().splitlines() if l.strip()]


def attach_alerts(namespace, monitors, wait=180):
    """Attach the alert channel to every monitor that should page.

    Done here rather than by AutoKuma: AutoKuma resolves notification names only
    against notifications it manages, and letting it manage the channel makes it
    rewrite that channel every ~5 seconds forever.

    Insert-only, so a channel a human attached by hand is never removed.
    """
    rows = kuma_sql(namespace,
                    f"select id from notification where name='{NOTIFICATION_NAME}';")
    if not rows:
        print(f"\n  no '{NOTIFICATION_NAME}' channel - nothing will notify you.")
        print("  Set UPTIME_KUMA_NTFY_TOPIC and redeploy uptime-kuma.")
        return 0
    nid = rows[0][0]

    # AutoKuma creates monitors asynchronously; wait for them rather than
    # attaching to a half-populated set.
    want = {m["name"] for m in monitors if m.get("_notify", True)}
    import time
    deadline = time.time() + wait
    while time.time() < deadline:
        have = {r[0] for r in (kuma_sql(namespace, "select name from monitor;") or [])}
        if want <= have:
            break
        time.sleep(5)

    ids = {r[0]: r[1] for r in (kuma_sql(namespace, "select name, id from monitor;") or [])}
    attached = {r[0] for r in (kuma_sql(
        namespace,
        "select m.name from monitor m join monitor_notification mn "
        f"on mn.monitor_id=m.id where mn.notification_id={nid};") or [])}
    added = 0
    for name in sorted(want):
        if name in attached or name not in ids:
            continue
        kuma_sql(namespace, "insert into monitor_notification (monitor_id, "
                            f"notification_id) values ({ids[name]}, {nid});")
        added += 1
    missing = sorted(want - set(ids))
    print(f"\n  alerting: {added} newly attached, {len(attached)} already, "
          f"{len(monitors) - len(want)} deliberately silent")
    if missing:
        # Loud: these were rendered but Kuma does not have them, so they cannot
        # be attached and are not being watched.
        print(f"  ⚠️  {len(missing)} rendered but absent from Uptime Kuma "
              f"(AutoKuma may be wedged): {', '.join(missing)}")
    return added


def main():
    import argparse
    ap = argparse.ArgumentParser(prog="uis monitors")
    ap.add_argument("action", choices=["render", "apply", "check"])
    ap.add_argument("--services-dir", default="/mnt/urbalurbadisk/provision-host/uis/services")
    ap.add_argument("--extend", default="/mnt/urbalurbadisk/.uis.extend/monitors.yaml")
    ap.add_argument("--namespace", default="monitoring")
    ap.add_argument("--outdir")
    ap.add_argument("--from", dest="ctx_from", metavar="CONTEXT",
                    help="kube context to DISCOVER services in (read-only). "
                         "Defaults to the current context")
    ap.add_argument("--to", dest="ctx_to", metavar="CONTEXT",
                    help="kube context where Uptime Kuma runs. Defaults to --from")
    ap.add_argument("--watchdog", choices=["auto", "in-cluster", "external"],
                    default="auto",
                    help="where Uptime Kuma runs. auto detects it by looking for "
                         "the service in the target cluster; override when "
                         "rendering for a watchdog that is not up yet")
    args = ap.parse_args()

    global CTX_FROM, CTX_TO
    CTX_FROM = args.ctx_from
    CTX_TO = args.ctx_to or args.ctx_from
    if CTX_FROM or CTX_TO:
        print(f"  discovering in: {CTX_FROM or '(current)'}   "
              f"watchdog in: {CTX_TO or '(current)'}")

    # Read from the WATCHDOG's cluster, not whichever context happens to be
    # current - with --from/--to they are different clusters.
    salt = os.environ.get("UPTIME_KUMA_PUSH_SALT") or read_secret_key(
        "uptime-kuma-push-salt", args.namespace)
    monitors, skipped, in_cluster = build(args.services_dir, args.extend, salt,
                                          args.watchdog)

    where = ("IN-CLUSTER (development topology - a watchdog here cannot report "
             "this cluster being down)" if in_cluster else
             "EXTERNAL (production topology)")
    print(f"  watchdog: {where}")
    print(f"  monitors: {len(monitors)}   not monitorable: {len(skipped)}")
    for m in monitors:
        print(f"    {m['type']:<8} {m['name']:<28} "
              f"{m.get('url') or str(m.get('hostname','')) + ':' + str(m.get('port',''))}")
    if skipped:
        # Loud on purpose. A deployed service with no monitor must never be
        # mistaken for a healthy one.
        print(f"\n  NOT MONITORED ({len(skipped)}):")
        for sid, why in skipped:
            print(f"    {sid}: {why}")

    if args.action == "render":
        if args.outdir:
            os.makedirs(args.outdir, exist_ok=True)
            for m in monitors:
                json.dump({k: v for k, v in m.items() if k != "_notify"},
                          open(f"{args.outdir}/{m['name']}.json", "w"), indent=2)
            print(f"\n  wrote {len(monitors)} files to {args.outdir}")
        return 0

    if args.action == "apply":
        import base64
        # _notify is UIS bookkeeping; AutoKuma must not see it.
        clean = [{k: v for k, v in m.items() if k != "_notify"} for m in monitors]
        data = {f"{m['name']}.json": base64.b64encode(
            json.dumps(m, indent=2).encode()).decode() for m in clean}
        secret = {"apiVersion": "v1", "kind": "Secret",
                  "metadata": {"name": "uptime-kuma-monitors",
                               "namespace": args.namespace},
                  "type": "Opaque", "data": data}
        p = subprocess.run(["kubectl"] + _ctx(CTX_TO) + ["apply", "-f", "-"],
                           input=json.dumps(secret), capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit(f"ERROR: {p.stderr.strip()}")
        print(f"\n  applied {len(monitors)} definitions to uptime-kuma-monitors")

        # ⚠️ REQUIRED, not an optimisation. The init container copies the Secret
        # into an emptyDir with `cp -L` (because AutoKuma will not follow the
        # symlinks Kubernetes projects), and that copy is made ONCE at pod
        # start. Updating the Secret alone changes nothing AutoKuma can see:
        # `apply` would report success and silently do nothing.
        print("  restarting AutoKuma so it re-reads the definitions...")
        subprocess.run(["kubectl"] + _ctx(CTX_TO) +
                       ["rollout", "restart", "deployment/autokuma",
                        "-n", args.namespace], capture_output=True, text=True)
        subprocess.run(["kubectl"] + _ctx(CTX_TO) +
                       ["rollout", "status", "deployment/autokuma",
                        "-n", args.namespace, "--timeout=300s"],
                       capture_output=True, text=True)
        attach_alerts(args.namespace, monitors)
        return 0

    if args.action == "check":
        # Compare intent against what Kuma is ACTUALLY running. AutoKuma
        # self-heals drift, so a stopped AutoKuma looks exactly like a healthy
        # one - checking only the Secret would miss that entirely.
        r = subprocess.run(
            ["kubectl"] + _ctx(CTX_TO) + ["exec", "-n", args.namespace,
             "uptime-kuma-0", "--", "sqlite3", "/app/data/kuma.db",
             "select name from monitor;"], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("ERROR: could not read Uptime Kuma - is it deployed?")
        live = {l.strip() for l in r.stdout.splitlines() if l.strip()}
        want = {m["name"] for m in monitors}
        missing, extra = sorted(want - live), sorted(live - want)
        if missing:
            print(f"\n  MISSING from Uptime Kuma ({len(missing)}) - NOT being "
                  f"monitored. If the definitions are applied, AutoKuma is "
                  f"wedged:")
            for n in missing:
                print(f"    - {n}")
        if extra:
            print(f"\n  in Uptime Kuma but not declared ({len(extra)}):")
            for n in extra:
                print(f"    - {n}")
        if not (missing or extra or skipped):
            print("\n  OK - Uptime Kuma matches what UIS deployed")
            return 0
        return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
