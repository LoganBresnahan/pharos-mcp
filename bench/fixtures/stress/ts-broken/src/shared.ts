// Clean module. Exports `greet`, consumed by both good.ts and broken.ts.
// Phase 4 probes target this file: the LSP must still answer
// references/definition queries even though a sibling file in the
// same workspace contains a syntax error.

export function greet(name: string): string {
  return `Hello, ${name}!`;
}

export const DEFAULT_NAME = "World";

export interface Greeter {
  greet(name: string): string;
}

export class FormalGreeter implements Greeter {
  greet(name: string): string {
    return `Greetings, ${name}.`;
  }
}
