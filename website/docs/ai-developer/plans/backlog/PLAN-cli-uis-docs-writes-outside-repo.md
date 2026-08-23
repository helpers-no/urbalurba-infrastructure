---
title: "`./uis docs` writes outside the repo and reports success"
status: backlog
type: PLAN
area: cli
severity: medium
created: 2026-08-23
---

# `./uis docs` writes outside the repo and reports success

## The defect

Run from a git checkout on a workstation:

```
$ ./uis docs
✓ Generated /mnt/urbalurbadisk/website/src/data/services.json (34 services)
✓ Generated /mnt/urbalurbadisk/website/src/data/categories.json (10 categories)
✓ JSON generation complete
$ git status --short website/src/data/
                                        # ← nothing. Exit code 0.
```

`/mnt/urbalurbadisk` is the path *inside the provision-host container*. On a
workstation it is either absent or an unrelated directory, so the generator
writes somewhere harmless and announces success. The counts in that output
(34 services / 10 categories) come from a stale copy, which makes the message
look plausible.

Running the same script directly does the right thing:

```
$ bash provision-host/uis/manage/uis-docs.sh
✓ Generated /home/tec/.../website/src/data/services.json (36 services)
```

## Why it matters

`services.json` is what the website's listings, category pages and search read.
A contributor who adds a service, runs `./uis docs`, and builds the site sees a
green build with their service missing from every listing — and the one command
that was supposed to fix it told them it had.

Found while adding browserless: the AUTOMATION category and the service were
both absent from the generated data after `./uis docs` reported success.

## Cause

`provision-host/uis/manage/uis-docs.sh` line 24 sets `SERVICES_DIR="$UIS_DIR/services"`,
but the output directory is resolved through `provision-host/uis/lib/paths.sh`,
which hardcodes the container prefix. Invoked directly the script derives paths
from its own location; invoked through `./uis` it inherits the exported
container paths.

So the *inputs* resolve to the checkout while the *outputs* resolve to the
container — which is why it half-works instead of failing outright.

## Fix

1. Derive the output directory the same way as the input directory: relative to
   the script's own location, walking up to the repo root.
2. If the resolved output directory does not exist, **fail** — do not create it
   and do not report success. A generator that cannot find the tree it is
   documenting should say so.
3. Print the paths it wrote relative to the repo root, so "wrote somewhere else"
   is visible rather than requiring the reader to notice an absolute prefix.

## Check it is actually fixed

The test is not "does `./uis docs` exit 0" — it already does. It is:

```bash
git checkout -- website/src/data/
./uis docs
git status --short website/src/data/    # must show modifications
```

And from inside the provision-host container, the same command must still write
to `/mnt/urbalurbadisk/website/src/data/` as it does today.

## Related

- The workaround is documented in
  [Adding a Service, Step 11a](../../../contributors/guides/adding-a-service.md),
  which now tells contributors to invoke the script directly.
- Same shape as [[PLAN-cli-test-all-coverage-and-dry-run]]: a command reporting
  on its own success rather than on the state it was supposed to produce.
