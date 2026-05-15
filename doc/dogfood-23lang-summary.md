## M14 Dogfood Cross-Pass Summary

23 languages × 39 tools real-fixture matrix. Four passes:

| Pass | Transport | Profile  | Cells | PASS    | Rate    |
|------|-----------|----------|-------|---------|---------|
|  1   | stdio     | all      | 524   | 370     | 70.6 %  |
|  2   | http      | all      | 524   | 376     | 71.8 %  |
|  3   | stdio     | default  | 524   | 371     | 70.8 %  |
|  4   | http      | default  | 524   | 376     | 71.8 %  |

Pre-M14 baseline was 351/524 (67 %). Post-M14 best is +25 cells / +4.8 pp.

### Headline findings

1. **Option B regression root-cause closed.** `decode_iolist_to_string`
   declared a `Result(String, _)` FFI signature for `unicode:characters_to_binary/1`
   which actually returns a raw binary. Pattern-match failed → pool actor
   crashed inside `describe_dynamic` whenever BEAM delivered the spawner's
   DOWN message before its `SpawnCompleted`. Replaced with
   `pharos_runtime_ffi:iolist_to_binary_safe/1` shim that absorbs the
   shape mismatch.

2. **Probe safety hardened.** `probe_call` now:
   * pre-checks `process.is_alive(proc.pid(spawned))` before each attempt,
     fast-fails as `lsp_proc died before probe` (sentinel matched in
     `probe_loop_step` to suppress doomed retries); and
   * wraps the inner `actor.call` in `pharos_runtime_ffi:safe_call_0/1`
     (try/catch) so the residual `is_alive`→`call` race surfaces as a
     typed error instead of a spawner exit.

   Pass 1c (post-FFI-fix, pre-probe-hardening) carried 1 raw
   `perform_call` panic; passes 2–4 carry zero.

3. **Transport delta.** HTTP edges out stdio by +5/+6 cells (perl + java
   recover under HTTP).

4. **Profile delta.** `default` filters debug/raw tools — those cells
   are recorded as graceful filter-rejections (PASS), giving +1 over the
   `all` profile under the same transport.

### Per-language pass count

Identical across passes except `perl` (5→10 under HTTP) and `java`
(16→17 under HTTP). See per-pass markdown reports for the cell-level
diff.

| Lang        | Cells | Best | Notes                                              |
|-------------|-------|------|----------------------------------------------------|
| typescript  | 22    | 20   | 2 SKIP (no type hierarchy on JS)                   |
| rust        | 22    | 20   | 2 SKIP                                              |
| cpp         | 22    | 20   | 2 SKIP                                              |
| clojure     | 22    | 20   | 2 SKIP                                              |
| haskell     | 22    | 20   | 2 SKIP                                              |
| python      | 40    | 37   | dual server pyright+ruff; 3 SKIP                   |
| go          | 22    | 19   | 1 server-error on call_hierarchy_prepare           |
| bash        | 22    | 18   | 4 SKIP                                              |
| css         | 22    | 18   | 4 SKIP                                              |
| html        | 22    | 18   | 4 SKIP                                              |
| json        | 22    | 18   | 4 SKIP                                              |
| lua         | 22    | 18   | 4 SKIP                                              |
| markdown    | 22    | 18   | 4 SKIP                                              |
| yaml        | 22    | 18   | 4 SKIP                                              |
| zig         | 22    | 18   | 4 SKIP                                              |
| terraform   | 22    | 17   | LSP gap (codeAction route)                         |
| java        | 22    | 17   | jdtls; 1 wall-clock timeout on goto_type_definition|
| ruby        | 22    | 15   | solargraph; 6 server gaps                          |
| elixir      | 22    | 14   | elixir-ls; protocol-undefined on -32603            |
| perl        | 22    | 10   | perlnavigator; flaky under stdio (5/22)            |
| **scala**   | 22    | 1    | metals init handshake fails. D-M14-003.            |
| **gleam**   | 22    | 1    | gleam-language-server init fails. D-M14-003.       |
| **erlang**  | 22    | 1    | elp binary not installed. D-M14-002.               |

### Failure mode distribution (Pass 4, representative)

| Count | Mode                                                                 |
|-------|----------------------------------------------------------------------|
|  42   | LSP spawn failed: lsp_proc died before probe (clean diagnostic)      |
|   3   | rust-analyzer failed to spawn: lsp_proc died before probe            |
|   3   | server error -32603: Timeout                                          |
|   3   | no LSP server claims textDocument/codeAction (registry gap)          |
|   3   | ready_timeout_ms exceeded by next backoff sleep                      |
|   2   | goto_type_definition: protocol error -32001 (HTTP transport timeout) |
|   2   | goto_implementation: protocol error -32000 (HTTP 500)                |
|   1   | goto/call_hierarchy: HTTP 500                                        |
|   1   | server error 0: flagConfig is not a function (go semantic)           |
|   1   | server error -32603: Protocol.UndefinedError (elixir-ls bug)         |
|   1   | server error -32098: no reference origin found                       |
|   1   | runtime_trace_calls disabled (config-gated, expected)                |

**Zero spawner-actor panics across passes 2–4.** Pool stays alive
through every cascade. Pre-FFI-fix Pass 1 reported 46 raw
`perform_call` exits; post-fix passes report them as typed
`lsp_proc died before probe` errors and continue.

### Open defects

* **D-M14-001 — PLS hang on goto_type_definition.** Tracked in
  `m14-test-plan.md`. Java + Go variants observed at the 645s harness
  cap with no LSP response. Likely server-side semantic, not pool.
* **D-M14-002 — erlang LSP missing.** Neither `elp` nor `erlang_ls`
  installed in the dev image. Erlang fixture forced to 1/22.
* **D-M14-003 — metals + gleam-language-server init failures.** Both
  binaries present; both die during initialize handshake (likely
  bloop/JVM and asdf-shim environment respectively).
* **HTTP 500 / -32000 / -32001 (Pass 2 + Pass 4).** 4 cells per HTTP
  pass return transport-level errors; not seen on stdio. Worth a
  follow-up pass against the HTTP request lifecycle / mist handler.

### Observability infrastructure landed

* `pharos/lsp/pool/trace` log channel — `pool_event` at Info on every
  Get, SpawnCompleted, SpawnProgress, DOWN.
* `runtime_lsp_state` extended with pool-level diag: `mailbox_len`,
  `inflight_key_count`, `inflight_waiter_total`,
  `spawner_monitor_count`, `lsp_child_monitor_count`, `cache_size`,
  plus per-entry `inflight_waiters`.
* `runtime_pool_recon` — pool process info, top-N mailboxes,
  `sys:get_state` dump, spawner stacktraces.
* `bin/dogfood-23lang.py --pool-trace-path` — JSONL snapshots at
  lang-start and after every tool call.

### What remains

* ADR for the M14 pool refactor (retroactive).
* Promote ADR-024 from Proposed to Accepted.
* D-M14-002 / D-M14-003 environmental fixes.
* HTTP 500 investigation.
