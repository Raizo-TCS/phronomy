#!/usr/bin/env python3
"""Run the bounded Agent terminal recovery ownership checks, keeping outputs outside the model tree."""

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--java", default="java")
    parser.add_argument("--case", action="append", dest="selected")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent
    jar = args.jar.resolve()
    output = args.output.resolve()
    if output == root or root in output.parents:
        parser.error("--output must be outside the model source directory")
    output.mkdir(parents=True, exist_ok=True)
    cases = json.loads((root / "cases.json").read_text())["cases"]
    if args.selected:
        unknown = set(args.selected) - {case["id"] for case in cases}
        if unknown:
            parser.error("unknown case(s): " + ", ".join(sorted(unknown)))
        cases = [case for case in cases if case["id"] in args.selected]
    model = root / "AgentTerminalRecovery.tla"
    version = subprocess.run([args.java, "-version"], text=True, capture_output=True)
    results = []
    for case in cases:
        work = output / case["id"]
        work.mkdir(exist_ok=True)
        config = root / (case["id"] + ".cfg")
        shutil.copy2(model, work / model.name)
        shutil.copy2(config, work / config.name)
        command = [args.java, "-XX:+UseParallelGC", "-Xmx1024m", "-cp", str(jar),
                   "tlc2.TLC", "-workers", "1", "-config", config.name,
                   "AgentTerminalRecovery"]
        completed = subprocess.run(command, cwd=work, text=True, capture_output=True)
        log = completed.stdout + completed.stderr
        (work / "tlc.log").write_text(log)
        kind = case["kind"]
        if kind == "property":
            matched = completed.returncode == 0 and "No error has been found" in log
        elif kind in {"missing_assumption", "mutation_liveness"}:
            matched = completed.returncode != 0 and "Temporal properties were violated" in log
        else:
            expected = "Invariant " + case["target"] + " is violated"
            matched = completed.returncode != 0 and expected in log
        counts = re.search(r"(\d+) states generated, (\d+) distinct states found", log)
        result = {**case, "matched_expected_result": matched,
                  "exit_code": completed.returncode, "command": command,
                  "config_sha256": sha256(config),
                  "generated_states": int(counts[1]) if counts else None,
                  "distinct_states": int(counts[2]) if counts else None,
                  "log": str(work / "tlc.log")}
        results.append(result)
        print(f"{case['id']}: {'matched' if matched else 'UNEXPECTED'} "
              f"({result['distinct_states']} states)", flush=True)
    summary = {"model_sha256": sha256(model), "jar_sha256": sha256(jar),
               "java_version": (version.stdout + version.stderr).strip(),
               "all_expected_results_matched": all(row["matched_expected_result"] for row in results),
               "results": results}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0 if summary["all_expected_results_matched"] else 1


if __name__ == "__main__":
    sys.exit(main())
