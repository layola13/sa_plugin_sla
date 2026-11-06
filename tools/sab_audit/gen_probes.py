#!/usr/bin/env python3
"""DEF-SAB-AUDIT probe generator (C' half).

Reads symbols.tsv (the curated symbol spec: live-example families
from the mapping report section 5 plus core-surface controls) and
the templates in templates/, and instantiates one probe program per
probe_id under probes/. A probe is an ordinary SLA @test program
exercising exactly one registered-surface symbol (or one documented
chain), so the matrix runner can compile it through BOTH backends
and record a per-symbol reachability verdict.

Also extracts the enumerable declaration plane from the std .sla
surface ($SA_STD_DIR/*.sla top-level fn names) into decl_rows.tsv:
those names resolve through the checker's imported_function_signatures
plane and are lowered generically on both backends, so the registry
records them as class=declared with status decl/decl instead of
spending probes on them.

Deterministic: same inputs -> byte-identical outputs.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def read_tsv(path):
    with open(path, encoding="utf-8") as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    header = lines[0].split("\t")
    rows = []
    for ln in lines[1:]:
        parts = ln.split("\t")
        parts += [""] * (len(header) - len(parts))
        rows.append(dict(zip(header, parts)))
    return rows


def main():
    spec = read_tsv(os.path.join(HERE, "symbols.tsv"))
    probes_dir = os.path.join(HERE, "probes")
    os.makedirs(probes_dir, exist_ok=True)

    # Clear previously generated probes so the set is exactly the spec.
    for name in os.listdir(probes_dir):
        if name.endswith(".sla"):
            os.unlink(os.path.join(probes_dir, name))

    seen = {}
    manifest = []
    for row in spec:
        pid = row["probe_id"]
        manifest.append(row)
        if pid in seen:
            continue
        tpl_path = os.path.join(HERE, "templates", row["template"] + ".sla.tpl")
        with open(tpl_path, encoding="utf-8") as fh:
            text = fh.read()
        if "{{BODY}}" in text:
            text = text.replace("{{BODY}}", row["body"])
        out = os.path.join(probes_dir, pid + ".sla")
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(text)
        seen[pid] = out

    with open(os.path.join(HERE, "manifest.tsv"), "w", encoding="utf-8") as fh:
        fh.write("probe_id\tsymbol\tclass\tnote\n")
        for row in manifest:
            fh.write("\t".join([row["probe_id"], row["symbol"], row["class"], row["note"]]) + "\n")

    # Declaration-plane extraction from the std .sla surface.
    sa_std_dir = os.environ.get("SA_STD_DIR", "")
    decl = []
    if sa_std_dir and os.path.isdir(sa_std_dir):
        fn_re = re.compile(r"^(?:pub\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
        for name in sorted(os.listdir(sa_std_dir)):
            if not name.endswith(".sla"):
                continue
            with open(os.path.join(sa_std_dir, name), encoding="utf-8", errors="replace") as fh:
                for ln in fh:
                    m = fn_re.match(ln.strip())
                    if m:
                        decl.append((m.group(1), name))
    with open(os.path.join(HERE, "decl_rows.tsv"), "w", encoding="utf-8") as fh:
        fh.write("symbol\tclass\ttext\tsab\tsignature\tprobe_id\tnote\n")
        for sym, src in sorted(set(decl)):
            fh.write("\t".join([sym, "declared", "decl", "decl", "", "",
                                 "std .sla declaration plane (from %s)" % src]) + "\n")
    print("gen_probes: %d probe files, %d symbol rows, %d declared-plane rows"
          % (len(seen), len(manifest), len(set(decl))))


if __name__ == "__main__":
    sys.exit(main())
