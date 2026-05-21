"""Polyglot stress fixture — python side."""


class PolyglotPyService:
    """Sentinel class for polyglot pool-spawn probe."""

    def __init__(self, label: str) -> None:
        self.label = label

    def render(self) -> str:
        return f"py:{self.label}"


def make_service(label: str) -> PolyglotPyService:
    return PolyglotPyService(label)


def main() -> None:
    svc = make_service("hello")
    print(svc.render())


if __name__ == "__main__":
    main()
