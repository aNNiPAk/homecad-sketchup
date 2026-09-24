Git policy

- Never combine unrelated changes in one commit.
- Before changing code, inspect git status and existing diff.
- Never discard user changes.
- Do not amend or rewrite existing commits unless explicitly requested.
- Do not use git reset --hard on user work.
- Commit only files belonging to the current task.
- Run relevant tests before creating a final task commit.
- Every commit must leave the repository in a coherent state.
- Prefer several small logical commits over one large commit.
- Use Conventional Commit messages.
- Do not commit .references/, temporary files, generated screenshots,
  local SketchUp models, secrets or machine-specific configuration.
  
For every completed milestone:

1. Run the full relevant test suite.
2. Update documentation.
3. Update CHANGELOG.md if the change is user-visible.
4. Commit the completed milestone.
5. Tag releases only after milestone acceptance.