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

HomeCAD architecture invariants

- Public geometry lengths are millimeters. Never expose raw SketchUp internal inches through MCP.
- The official SketchUp Ruby API is the source of truth for SketchUp behavior.
- Inspect the model before mutating it. Resolve every mutation target explicitly through the shared `Targeting` resolver; never choose the first match when a target is ambiguous.
- Every HomeCAD mutation maps to one SketchUp Undo operation and uses `HomeCAD::Operation`. Never create nested HomeCAD operations.
- Read-only inspection must never assign HomeCAD metadata.
- HomeCAD tools must not manually edit generated domain geometry. Update its parameters and regenerate it.
- Prefer first-class HomeCAD domain tools. Primitive tools are fallback or developer capabilities, not the main domain API.
- If introduced later, `eval_ruby` is an escape hatch and must not be used for normal workflows.
- Read reference repository licenses before copying code.
- Do not copy AGPL code from SidhNor/sketchup-mcp-server. It may be used only as an architectural reference unless licensing is explicitly reconsidered.
