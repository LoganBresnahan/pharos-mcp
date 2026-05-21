// DELIBERATELY BROKEN. Phase 4 stress fixture: an unterminated
// function declaration + missing semicolon + dangling brace. tsserver
// reports parse errors here; pharos should surface those diagnostics
// without abandoning queries against the rest of the workspace.

import { greet } from "./shared.js";

export function brokenGreet(name: string {
  // missing close-paren above, missing body brace below
  return greet(name)
