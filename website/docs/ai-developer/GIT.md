---
mdx:
  format: md
---

# Git Safety Rules and Operations

Git operations require user confirmation. The AI must never run destructive git commands without explicit approval.

---

## Safety Rules

### NEVER run these commands without user confirmation:

- `git add`
- `git commit`
- `git push`
- `git checkout -b` (create branch)
- `git merge`
- `git branch -d` / `git branch -D` (delete branch)
- `git reset --hard`
- `git push --force`
- `git rebase`

### Always:

- **Show the command** before running it
- **Wait for approval** — "OK to proceed?"
- **Explain what it does** if the user might not know

### Never:

- Skip hooks (`--no-verify`)
- Force push to main/master
- Amend published commits without asking
- Delete branches without asking

---

## Branch Naming

| Context | Pattern | Example |
|---------|---------|---------|
| Feature work | `feature/<short-name>` | `feature/add-search` |
| Bug fix | `fix/<short-name>` | `fix/mobile-nav` |
| From an issue | `issue-<number>-<short-name>` | `issue-42-auth-bug` |

---

## Common Operations

### Create a feature branch

```bash
git checkout -b feature/my-feature
```

### Commit changes

```bash
git add <specific-files>
git commit -m "Description of changes"
```

Prefer adding specific files over `git add .` or `git add -A` to avoid accidentally committing sensitive files.

### Push and create PR

```bash
git push -u origin feature/my-feature
```

Then create a Pull Request (see platform-specific sections below).

### Merge and clean up

```bash
git checkout main
git pull
git branch -d feature/my-feature
```

---

## GitHub Operations

Use the GitHub CLI (`gh`) for GitHub-specific operations.

### Create a Pull Request

```bash
gh pr create --title "Add feature X" --body "Description of changes"
```

### View an issue

```bash
gh issue view <number>
```

### Close an issue

```bash
gh issue close <number> --comment "Fixed in commit <hash>"
```

### List open issues

```bash
gh issue list
```

### Merge a Pull Request

```bash
gh pr merge <number> --merge
```

---

## Azure DevOps Operations

Use the Azure CLI (`az`) for Azure DevOps operations.

### Create a Pull Request

```bash
az repos pr create --title "Add feature X" --description "Description of changes" --source-branch feature/my-feature --target-branch main
```

### Link to a work item

```bash
az repos pr create --title "Add feature X" --work-items <work-item-id> --source-branch feature/my-feature --target-branch main
```

### List Pull Requests

```bash
az repos pr list --status active
```

### Complete a Pull Request

```bash
az repos pr update --id <pr-id> --status completed
```

---

## Commit Message Style

Follow the existing commit message style in the repository. Check recent commits:

```bash
git log --oneline -10
```

General guidelines:
- Start with a verb (Add, Fix, Update, Remove, Refactor)
- Keep the first line under 72 characters
- Use the body for details if needed
