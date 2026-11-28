#!/usr/bin/env python3
"""Run the bounded Handoff protocol checks, keeping outputs outside the model tree."""

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
    parser.add_argument("--module", choices=["HandoffDispatchRecovery", "HandoffTerminalFinalization"])
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent
    jar = args.jar.resolve()
    expected_jar_sha = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
    if sha256(jar) != expected_jar_sha:
        parser.error("TLC JAR SHA-256 differs from the pinned tool")
    output = args.output.resolve()
    if output == root or root in output.parents:
        parser.error("--output must be outside the model source directory")
    output.mkdir(parents=True, exist_ok=True)
    cases = json.loads((root / "cases.json").read_text())["cases"]
    for case in cases:
        companion = root / (case["id"] + ".cfg")
        if companion.read_text() != case["configuration"]:
            parser.error("case manifest and companion configuration differ: " + case["id"])
    if args.selected:
        unknown = set(args.selected) - {case["id"] for case in cases}
        if unknown:
            parser.error("unknown case(s): " + ", ".join(sorted(unknown)))
        cases = [case for case in cases if case["id"] in args.selected]
    if args.module:
        cases = [case for case in cases if case.get("module", "HandoffDispatchRecovery") == args.module]
    if not cases:
        parser.error("selection contains no cases")
    models = {case.get("module", "HandoffDispatchRecovery") for case in cases}
    if not models <= {"HandoffDispatchRecovery", "HandoffTerminalFinalization"}:
        parser.error("case manifest contains an unknown module")
    version = subprocess.run([args.java, "-version"], text=True, capture_output=True)
    results = []
    for case in cases:
        module = case.get("module", "HandoffDispatchRecovery")
        model = root / (module + ".tla")
        work = output / case["id"]
        work.mkdir(exist_ok=True)
        config = work / (case["id"] + ".cfg")
        config.write_text(case["configuration"])
        shutil.copy2(model, work / model.name)
        command = [args.java, "-XX:+UseParallelGC", "-Xmx1024m", "-cp", str(jar),
                   "tlc2.TLC", "-workers", "1", "-config", config.name,
                   module]
        completed = subprocess.run(command, cwd=work, text=True, capture_output=True)
        log = completed.stdout + completed.stderr
        (work / "tlc.log").write_text(log)
        kind = case["kind"]
        if kind == "property":
            matched = completed.returncode == 0 and "No error has been found" in log
        elif kind in {"missing_assumption", "mutation_liveness"} and not case.get("target"):
            matched = completed.returncode != 0 and "Temporal properties were violated" in log
        else:
            expected = "Invariant " + case["target"] + " is violated"
            matched = completed.returncode != 0 and expected in log
        counts = re.search(r"(\d+) states generated, (\d+) distinct states found", log)
        result = {**{key: value for key, value in case.items() if key != "configuration"},
                  "module": module, "model_sha256": sha256(model),
                  "matched_expected_result": matched,
                  "exit_code": completed.returncode, "command": command,
                  "config_sha256": sha256(config),
                  "log_sha256": sha256(work / "tlc.log"),
                  "generated_states": int(counts[1]) if counts else None,
                  "distinct_states": int(counts[2]) if counts else None,
                  "log": str(work / "tlc.log")}
        results.append(result)
        print(f"{case['id']}: {'matched' if matched else 'UNEXPECTED'} "
              f"({result['distinct_states']} states)", flush=True)
    summary = {"model_sha256": sha256(root / (next(iter(models)) + ".tla")) if len(models) == 1 else None,
               "module_sha256": {name: sha256(root / (name + ".tla")) for name in sorted(models)},
               "jar_sha256": sha256(jar),
               "sources_sha256": {path.name: sha256(path) for path in sorted(root.iterdir())
                                  if path.is_file()},
               "java_version": (version.stdout + version.stderr).strip(),
               "all_expected_results_matched": all(row["matched_expected_result"] for row in results),
               "results": results}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0 if summary["all_expected_results_matched"] else 1


if __name__ == "__main__":
    sys.exit(main())
