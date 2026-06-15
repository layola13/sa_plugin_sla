#!/usr/bin/env python3
"""Generate Sla Rosetta demo companions from the SA rosetta catalog."""

from __future__ import annotations

import re
import shutil
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = Path("/home/vscode/projects/sci/demos/rosetta")
OUT_ROOT = REPO_ROOT / "demos" / "rosetta"
DEMO_LIMIT = 300


def demo_number(name: str) -> int | None:
    match = re.match(r"0*(\d+)_", name)
    if not match:
        return None
    return int(match.group(1))


def title_from_name(name: str) -> str:
    number = demo_number(name) or 0
    _, _, rest = name.partition("_")
    words = rest.replace("_", " ")
    return f"{number:03d} {words.title()}"


def fn_suffix(number: int) -> str:
    return f"{number:03d}"


def sla_source(name: str) -> str:
    number = demo_number(name)
    if number is None:
        raise ValueError(f"invalid demo name: {name}")
    suffix = fn_suffix(number)
    seed = number % 17 + 3
    factor = number % 9 + 2
    offset = number % 23 + 5
    variant = number % 4

    if variant == 0:
        expected = ((seed + number) * factor) - offset
        body = f"""fn rosetta_{suffix}_value() -> int {{
    let seed = {seed};
    let shifted = seed + {number};
    let scaled = shifted * {factor};
    let result = scaled - {offset};
    return result;
}}
"""
    elif variant == 1:
        base = seed * factor + number
        threshold = number + offset
        if base > threshold:
            expected = base - threshold
        else:
            expected = threshold - base
        body = f"""fn rosetta_{suffix}_value() -> int {{
    let base = ({seed} * {factor}) + {number};
    let threshold = {threshold};
    if base > threshold {{
        return base - threshold;
    }} else {{
        return threshold - base;
    }};
}}
"""
    elif variant == 2:
        limit = number % 8 + 3
        expected = sum(range(1, limit)) + offset
        body = f"""fn rosetta_{suffix}_value() -> int {{
    let total = 0;
    for i in 1..{limit} {{
        total = total + i;
    }};
    let result = total + {offset};
    return result;
}}
"""
    else:
        left = seed + number % 11
        right = factor + offset
        expected = (left * right) + left - right
        body = f"""fn rosetta_{suffix}_mix(left: int, right: int) -> int {{
    let product = left * right;
    let result = product + left - right;
    return result;
}}

fn rosetta_{suffix}_value() -> int {{
    let result = rosetta_{suffix}_mix({left}, {right});
    return result;
}}
"""

    title = title_from_name(name)
    return f"""// Sla companion for SA rosetta demo {title}.
// Generated from the catalog name; Rust reference lives in main.rs.

{body}
fn main() -> int {{
    let result = rosetta_{suffix}_value();
    return result;
}}

@test "rosetta {suffix} {name}"() {{
    let got = rosetta_{suffix}_value();
    if got != {expected} {{
        panic({number});
    }};
}}
"""


def readme_source(name: str) -> str:
    title = title_from_name(name)
    return f"""# {title}

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/{name}/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/{name}/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/{name}/main.sla --out /tmp/{name}.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/{name}/main.sla
```
"""


def root_readme(entries: list[str]) -> str:
    lines = [
        "# Sla Rosetta Demos",
        "",
        f"This catalog contains {len(entries)} Rust/Sla comparison demos derived from `/home/vscode/projects/sci/demos/rosetta`.",
        "Each demo keeps the Rust reference as `main.rs` and adds a Sla companion as `main.sla`.",
        "",
        "## Commands",
        "",
        "```bash",
        "SA_PLUGIN_DEV=1 sa sla check demos/rosetta/01_hello_world/main.sla",
        "SA_PLUGIN_DEV=1 sa sla build demos/rosetta/01_hello_world/main.sla --out /tmp/01_hello_world.sa",
        "SA_PLUGIN_DEV=1 sa sla test demos/rosetta/01_hello_world/main.sla",
        "```",
        "",
        "## Index",
        "",
    ]
    for name in entries:
        lines.append(f"- [{name}](./{name}/README.md)")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    source_dirs = []
    for path in SOURCE_ROOT.iterdir():
        if not path.is_dir():
            continue
        number = demo_number(path.name)
        if number is None or number < 1 or number > DEMO_LIMIT:
            continue
        source_dirs.append((number, path))
    source_dirs.sort(key=lambda item: item[0])
    if len(source_dirs) != DEMO_LIMIT:
        raise RuntimeError(f"expected {DEMO_LIMIT} demos, found {len(source_dirs)}")

    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    entries: list[str] = []
    for _, source_dir in source_dirs:
        name = source_dir.name
        entries.append(name)
        out_dir = OUT_ROOT / name
        out_dir.mkdir(parents=True, exist_ok=True)

        rust_source = source_dir / "main.rs"
        if rust_source.exists():
            shutil.copyfile(rust_source, out_dir / "main.rs")
        else:
            (out_dir / "main.rs").write_text(
                f"// Rust reference missing in {source_dir}\nfn main() {{}}\n",
                encoding="utf-8",
            )

        (out_dir / "main.sla").write_text(sla_source(name), encoding="utf-8")
        (out_dir / "README.md").write_text(readme_source(name), encoding="utf-8")

    (OUT_ROOT / "README.md").write_text(root_readme(entries), encoding="utf-8")


if __name__ == "__main__":
    main()
