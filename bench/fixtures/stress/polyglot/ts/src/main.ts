// Polyglot stress fixture — typescript side.

export class PolyglotTsService {
  constructor(public readonly label: string) {}

  render(): string {
    return `ts:${this.label}`;
  }
}

export function makeService(label: string): PolyglotTsService {
  return new PolyglotTsService(label);
}

function main(): void {
  const svc = makeService("hello");
  console.log(svc.render());
}

main();
