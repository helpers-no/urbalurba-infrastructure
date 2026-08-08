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


def kubectl_json(args):
    r = subprocess.run(["kubectl"] + args + ["-o", "json"],
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
    d = kubectl_json(["get", "svc,endpoints,ingress", "-A"])
    for i in d.get("items", []):
        k, md = i["kind"], i["metadata"]
        if k in ("Service", "Endpoints"):
            out[k][(md["namespace"], md["name"])] = i
        elif k == "Ingress":
            out["Ingress"].append(i)
    # IngressRoute is a CRD and may not exist (no Traefik). Not an error.
    try:
        d = kubectl_json(["get", "ingressroute", "-A"])
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


def watchdog_is_in_cluster(cluster, namespace="monitoring"):
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


def render_monitor(name, kind, value, probe):
    """One AutoKuma static-monitor definition.

    ⚠️ Never emits notification_name_list. AutoKuma resolves that only against
    notifications IT manages, and letting it manage the channel makes it rewrite
    the channel every ~5s forever. The setup playbook owns the channel and its
    attachments instead.
    """
    o = {"name": name,
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
        in_cluster = watchdog_is_in_cluster(cluster)
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
            elif m["type"] == "push":
                if not salt:
                    sys.exit("ERROR: a push monitor needs uptime-kuma-push-salt "
                             "in urbalurba-secrets - without it the heartbeat "
                             "URL cannot be derived and would change on rebuild")
                o["push_token"] = push_token(salt, m["name"])
            monitors.append(o)

    return monitors, skipped, in_cluster


def main():
    import argparse
    ap = argparse.ArgumentParser(prog="uis monitors")
    ap.add_argument("action", choices=["render", "apply", "check"])
    ap.add_argument("--services-dir", default="/mnt/urbalurbadisk/provision-host/uis/services")
    ap.add_argument("--extend", default="/mnt/urbalurbadisk/.uis.extend/monitors.yaml")
    ap.add_argument("--namespace", default="monitoring")
    ap.add_argument("--outdir")
    ap.add_argument("--watchdog", choices=["auto", "in-cluster", "external"],
                    default="auto",
                    help="where Uptime Kuma runs. auto detects it by looking for "
                         "the service in the target cluster; override when "
                         "rendering for a watchdog that is not up yet")
    args = ap.parse_args()

    salt = os.environ.get("UPTIME_KUMA_PUSH_SALT")
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
                json.dump(m, open(f"{args.outdir}/{m['name']}.json", "w"), indent=2)
            print(f"\n  wrote {len(monitors)} files to {args.outdir}")
        return 0

    if args.action == "apply":
        import base64
        data = {f"{m['name']}.json": base64.b64encode(
            json.dumps(m, indent=2).encode()).decode() for m in monitors}
        secret = {"apiVersion": "v1", "kind": "Secret",
                  "metadata": {"name": "uptime-kuma-monitors",
                               "namespace": args.namespace},
                  "type": "Opaque", "data": data}
        p = subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(secret),
                           capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit(f"ERROR: {p.stderr.strip()}")
        print(f"\n  applied {len(monitors)} definitions to uptime-kuma-monitors")
        return 0

    if args.action == "check":
        # Compare intent against what Kuma is ACTUALLY running. AutoKuma
        # self-heals drift, so a stopped AutoKuma looks exactly like a healthy
        # one - checking only the Secret would miss that entirely.
        r = subprocess.run(
            ["kubectl", "exec", "-n", args.namespace, "uptime-kuma-0", "--",
             "sqlite3", "/app/data/kuma.db", "select name from monitor;"],
            capture_output=True, text=True)
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
