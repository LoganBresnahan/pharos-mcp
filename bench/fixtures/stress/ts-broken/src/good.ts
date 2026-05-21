// Clean consumer of shared.ts. References `greet`, `DEFAULT_NAME`,
// and `FormalGreeter`. Used by Phase 4 stress probes to confirm
// pharos can resolve references across files even when the same
// workspace contains a separate file (broken.ts) with a parse error.

import { greet, DEFAULT_NAME, FormalGreeter } from "./shared.js";

export function defaultGreeting(): string {
  return greet(DEFAULT_NAME);
}

export function formalDefaultGreeting(): string {
  const g = new FormalGreeter();
  return g.greet(DEFAULT_NAME);
}
