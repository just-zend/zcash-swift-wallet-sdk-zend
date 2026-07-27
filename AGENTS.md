# Agent instructions

Repository-specific guidance for coding agents lives in `CLAUDE.md`. The
conventions below apply to agent-generated working documents in this
repository.

## Plans and design documents are not committed

Plans, design specs, and brainstorming documents are working artifacts of a
development session, not repository history. Never commit them.

Standard handling:

- Write them to the `.plans/` directory at the repository root, which is
  listed in `.gitignore`.
- If `.plans/` does not exist yet, create it (and ensure `.plans/` appears in
  the checked-in `.gitignore`).
- After writing a plan or spec, report its full absolute path, untruncated,
  so it can be copy-pasted.
