"""Core module — Phase 4 stress probe target.

Exercises basic class + function definitions for the LSP to index.
References are deliberately limited to in-file uses so Phase 4
collision/refs Q are well-defined."""


class Engine:
    """Trivial engine with a settings hook."""

    def __init__(self, name: str) -> None:
        self.name = name

    def fire(self) -> str:
        return f"{self.name}.fire"

    def shutdown(self) -> None:
        pass


def run_default() -> str:
    """Build a default engine and fire it."""
    engine = Engine("default")
    return engine.fire()


def secondary_call() -> str:
    """Second consumer of Engine.fire — used for refs_count > 1."""
    e = Engine("secondary")
    return e.fire()
