# Claude Code Instructions

Project-specific instructions for Claude Code when working on urbalurba-infrastructure.

## Plan Workflow

**BEFORE implementing any plan, read these files for context:**
- `website/docs/ai-developer/PLANS.md` - Plan structure, templates, and best practices
- `website/docs/ai-developer/WORKFLOW.md` - Implementation workflow and process

When implementing a plan from `website/docs/ai-developer/plans/`:

1. **Read the full plan first** - understand all phases before starting
2. **Work phase by phase** - never skip ahead
3. **Update the plan file as you go:**
   - Mark current phase: `## Phase N: Name — IN PROGRESS`
   - Check off completed tasks: `- [x] Task description`
   - Mark finished phases: `## Phase N: Name — ✅ DONE`
4. **Stop after each phase** - ask user: "Phase N complete. Does this look good to continue?"
5. **Wait for user confirmation** before starting the next phase

## Creating Plans

When user requests a new feature or fix:

1. Read `website/docs/ai-developer/PLANS.md` for templates and structure
2. Create plan file in `website/docs/ai-developer/plans/backlog/`
3. Ask user to review the plan before implementing
4. When user approves, ask: "Do you want to work on a feature branch? (recommended)"
5. Only move to `active/` after user approves

## Git Commits

- Ask for confirmation before running git commands (add, commit, push)
- Use feature branches for multi-phase work
- Commit after each phase (with user approval)

## Infrastructure Work

When working with Kubernetes manifests and infrastructure:

1. **Manifest numbering** - Follow conventions in `manifests/` folder:
   - 000-099: Core infrastructure
   - 040-099: Databases and caches
   - 070-079: Authentication
   - 200-229: AI services
   - 030-039: Monitoring
   - 600-799: Admin tools

2. **Validate before committing:**
   ```bash
   kubectl apply --dry-run=client -f manifests/xxx-new-service.yaml
   ```

3. **Test deployments:**
   ```bash
   kubectl rollout status deployment/xxx -n namespace
   kubectl get pods -n namespace
   ```

## Documentation

All documentation is in `website/docs/` (Docusaurus):

- Getting started: `website/docs/getting-started/`
- Packages: `website/docs/packages/`
- Platforms: `website/docs/platforms/`
- AI developer docs: `website/docs/ai-developer/`
- Plans: `website/docs/ai-developer/plans/`

**When working with documentation:**
- Run dev server: `cd website && npm run start`
- Build: `cd website && npm run build`

## Key Files

- `CLAUDE.md` (repo root) - Main project instructions
- `manifests/` - Kubernetes manifest files
- `ansible/playbooks/` - Ansible automation
- `provision-host/` - Provisioning scripts
