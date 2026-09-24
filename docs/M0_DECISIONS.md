# M0 bootstrap: implementation decisions

## Scope and sequence

1. Define the two-tool contract and wire errors.
2. Build a loopback Ruby extension with nonblocking, timer-driven TCP handling and test it outside SketchUp.
3. Build the Python stdio MCP adapter, test protocol failures and the two tool paths, then package the RBZ.
4. Run the complete automated suite. Validate in SketchUp manually on Windows after installation.

This implements section 7 and section 33 of `IMPLEMENTATION_PLAN.md`. It does not add scene inspection, geometry, or arbitrary Ruby execution. `Operation.run` and centralized units conversion are present for later mutating tools; neither M0 tool mutates the model.

## Wire protocol

Bind only `127.0.0.1`. Port defaults to `37941` on both sides and can be changed with `HOMECAD_PORT` before starting both processes. Each TCP connection carries exactly two JSON-RPC 2.0 requests: `hello`, then one of `homecad_status` or `get_model_info`. Each JSON body is UTF-8 with a four-byte unsigned big-endian length prefix. Frames are limited to 1 MiB. The Python side opens a fresh connection for each tool call, avoiding stale persistent connection state and ambiguous retries. The Ruby side reads and writes without blocking in a `UI.start_timer` callback, so SketchUp API access stays on its main thread. The Python side enforces an end-to-end timeout.

`hello` sends `protocol_version: 1` and `client_version: 0.1.0`. Ruby rejects a different protocol or client major version. Python independently rejects a different protocol or Ruby extension major version. Minor and patch releases within the same major version are compatible until a breaking protocol revision is needed. An absent SketchUp server is `connection_error`; a mismatched version is `incompatible_version`. No automatic retry is made after a request is sent.

`homecad_status` returns MCP version, Ruby extension version, SketchUp version, model name, connection status and protocol version. `get_model_info` returns model name, file title/path, model GUID, modified flag and counts for root entities, active entities and selection. An unsaved unnamed model is named `(Untitled)`; its path is `null`. Entity counts are scoped to the named collections, not recursive totals.

## References reviewed

| Repository | Commit SHA | Files studied | Used idea | Deliberately omitted |
| --- | --- | --- | --- | --- |
| zinin/sketchup-mcp2 | `70c6edb50f4edbeaacdda1726ce93c4ba46fc1c0` | Python `connection.py`, `config.py`, `server.py`; Ruby `core/server.rb`, `core/framing.rb`, `core/compat.rb`, `handlers/model.rb`, `package.rb`; framing and handshake tests | Bounded length-prefixed JSON, handshake validation, timer-driven main-thread bridge, structured errors | Persistent/multi-command sockets and the component/woodworking surface |
| Shattenjagger/sketchup-mcp-bridge | `c7ee20c1f01a691dfdd903df7aa46b49b827b830` | Python `client.py`, `tests/test_client.py`; Ruby `main.rb`; `scripts/build_rbz.py` | Connect-per-command simplicity and small RBZ packaging | Blocking `gets` in a UI timer, unrestricted eval, unbounded line input |
| darwin/supex | `66c9eed0921c418be3f1bd4ef5f100f6b5f2ad4c` | Ruby `bridge_server.rb`, `main.rb`, `operation.rb`, `test_bridge_server.rb`; Python `sketchup_connection.py` | Main-thread timer handling and one-operation helper | REPL, VCAD, sidecars and other MVP-unrelated runtime layers |
| SidhNor/sketchup-mcp-server | `75b851cbfb145fdfb444ed4c769216095c655c02` | `target_reference_resolver.rb`, `managed_mutation_helper.rb`, resolver tests, `LICENSE` | Architecture reminder to reject ambiguous targets in a later milestone | All source code; checkout license is AGPL-3.0 |

No source code was copied from these repositories. The official [SketchUp Ruby API](https://ruby.sketchup.com/) is the source of truth for main-thread access, [`UI.start_timer`](https://ruby.sketchup.com/UI.html), [`Sketchup::Model`](https://ruby.sketchup.com/Sketchup/Model.html) and [RBZ structure](https://ruby.sketchup.com/file.extension_requirements.html).
