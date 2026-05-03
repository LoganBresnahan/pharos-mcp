//// Library entry / facade for `llm_lsp_mcp`.
////
//// `main/0` is the CLI entrypoint — invoked from Mix via the
//// `start` alias defined in mix.exs (`mix start`). Reads NDJSON
//// JSON-RPC messages from stdin one line at a time, dispatches via
//// `mcp/server`, and writes replies to stdout.
////
//// In Milestone 1 the stdio loop is plain recursive function — no
//// OTP supervision yet. Supervised lifecycle arrives in Milestone 2
//// when LSP clients are added (each LSP requires crash-recovery).

import llm_lsp_mcp/log
import llm_lsp_mcp/lsp/pool.{type Pool}
import llm_lsp_mcp/mcp/server
import llm_lsp_mcp/mcp/stdio

pub fn main() -> Nil {
  log.info("llm_lsp_mcp starting (stdio transport)")
  case pool.start() {
    Error(_) -> {
      log.error("failed to start LSP pool; exiting")
      Nil
    }
    Ok(p) -> {
      log.info("LSP pool started")
      loop(p)
    }
  }
}

fn loop(pool: Pool) -> Nil {
  case stdio.read_line() {
    stdio.StdinEof -> {
      log.info("stdin closed; shutting down LSP pool")
      pool.close_all(pool)
      Nil
    }

    stdio.StdinError(reason) -> {
      log.error("stdin read error: " <> reason)
      pool.close_all(pool)
      Nil
    }

    stdio.StdinLine(line) -> {
      let trimmed = stdio.trim_trailing_newline(line)
      case trimmed {
        "" -> Nil
        body ->
          case server.handle_line(pool, body) {
            server.Reply(json) -> stdio.write(json)
            server.NoReply -> Nil
            server.ProtocolError(json) -> stdio.write(json)
          }
      }
      loop(pool)
    }
  }
}
