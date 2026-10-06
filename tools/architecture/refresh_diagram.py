#!/usr/bin/env python3
"""Validate a declared refactoring phase, then draw dependencies from Ruby source.

This is a static boundary gate, not a replacement for Ruby/RBS/runtime tests.
It never modifies the repository and never rewrites extracted dependency edges.
"""

import argparse
from collections import deque
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "tools"))
from check_abstractions import violations as abstraction_violations
from find_dependency_triangles import analyze as triangles, write_report as write_triangles

ENGINE = "lib/phronomy/engine"
BASELINE_COMMIT = "84668606523e8b013ccb1cf1144694ecd28f24f8"
FEATURES = ["llm_adapter", "vector_store", "vector_store/embeddings", "storage"]
CLIENTS = {"lib/phronomy/" + f + "/async" for f in [*FEATURES, "embeddings"]}
BASE_MODULES = {"lib/phronomy/" + f for f in [*FEATURES, "embeddings", "documents/loader", "documents/splitter", "llm_contract", "llm_context_window", "vector_store/loader", "vector_store/splitter", "storage/backends"]}
IMPLEMENTATIONS = {
    "lib/phronomy/embeddings/backends": "lib/phronomy/embeddings",
    "lib/phronomy/llm_adapter/backends": "lib/phronomy/llm_adapter",
    "lib/phronomy/vector_store/backends": "lib/phronomy/vector_store",
    "lib/phronomy/vector_store/embeddings/backends": "lib/phronomy/vector_store/embeddings",
    "lib/phronomy/storage/backends": "lib/phronomy/storage",
}
PHASES = {
    "baseline": {"features": [], "remaining": ["llm_adapter", "vector_store", "vector_store/embeddings"]},
    "llm": {"features": ["llm_adapter"], "remaining": ["vector_store", "vector_store/embeddings"]},
    "vector": {"features": ["llm_adapter", "vector_store", "vector_store/embeddings"], "remaining": []},
    "storage": {"features": FEATURES, "remaining": []},
}


def read_architecture(phase):
    return json.loads((HERE / "config" / (phase + ".architecture.json")).read_text())


def beneath(path, root):
    return path == root or path.startswith(root + "/")


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def path_to(graph, start, forbidden):
    queue = deque([[start]])
    seen = {start}
    while queue:
        route = queue.popleft()
        for target in sorted(graph.get(route[-1], set())):
            if forbidden(target):
                return route + [target]
            if target not in seen:
                seen.add(target)
                queue.append(route + [target])
    return None


def check_boundaries(audit, phase, repo, architecture=None):
    policy = PHASES[phase]
    architecture = architecture or read_architecture(phase)
    kinds = {g["id"]: g["kind"] for g in architecture["groups"]}
    roles = {m["directory"]: kinds[m["group"]] for m in architecture["modules"]}
    modules = {m["directory"] for m in audit["modules"]}
    graph = {}
    pairs = {(p["from"], p["to"]) for p in audit["module_pairs"]}
    for source, target in pairs:
        graph.setdefault(source, set()).add(target)
    violations = []
    if modules != set(roles):
        violations.append({"kind": "module-configuration-mismatch", "added": sorted(modules-set(roles)), "missing": sorted(set(roles)-modules)})
    expected = {("lib/phronomy/" + f, ENGINE) for f in policy["remaining"]}
    actual = {(a,b) for a,b in pairs if a in BASE_MODULES and beneath(b,ENGINE)}
    if actual != expected:
        violations.append({"kind":"legacy-engine-edges", "expected":sorted(expected), "actual":sorted(actual)})
    # Rules use semantic roles, never group numbers, drawing order or coordinates.
    forbidden_roles = {
        "backend_contracts": {"backend_implementations", "async_clients", "engine", "mixed_backend", "domain", "support", "content_service"},
        "backend_implementations": {"async_clients", "engine", "domain", "support", "content_service"},
        "engine": {"backend_contracts", "backend_implementations", "async_clients", "mixed_backend", "domain", "content_service"},
        "async_clients": {"backend_implementations", "mixed_backend", "domain", "support", "content_service"},
        "document_processing": {"engine", "async_clients"},
        "token_budget": {"engine", "async_clients"},
    }
    # Execution APIs contain mechanisms, unlike neutral shared vocabulary.
    # Moving an API out of engine/ must not let a synchronous backend reach it.
    for role in ["backend_contracts", "backend_implementations", "document_processing", "token_budget"]:
        forbidden_roles[role].add("execution_services")
    # In r8 the previously separate services and values share one framework.
    # Synchronous backend extensions do not acquire that execution dependency.
    if architecture.get("execution_framework_unified", False):
        for role in ["backend_contracts", "backend_implementations", "document_processing", "token_budget"]:
            forbidden_roles[role].add("execution_contracts")
    forbidden_roles["execution_services"] = set(forbidden_roles["engine"])
    forbidden_roles["engine"].add("execution_services")
    forbidden_roles["engine_concurrency"] = forbidden_roles["engine"] | {"engine"}
    for role in ["backend_contracts", "backend_implementations", "document_processing", "token_budget"]:
        forbidden_roles[role].add("engine_concurrency")
    # A domain binding joins its own framework to Engine; it is not the
    # neutral Engine. Existing lower-level roles must not reach this binding.
    for denied_roles in forbidden_roles.values():
        if "domain" in denied_roles or "engine" in denied_roles:
            denied_roles.add("domain_binding")
    if architecture.get("r8_unit7_contracts"):
        progress = {"lib/phronomy/agent/" + name for name in
                    ("execution", "recovery", "recovery/recovery_coordinator", "lifecycle")}
        for source, target in sorted(pairs):
            if source in progress and (beneath(target, ENGINE) or roles.get(target) == "domain_binding"):
                violations.append({"kind": "agent-progress-selects-engine", "pair": (source, target)})
    if architecture.get("r8_unit10_contracts"):
        for source, target in sorted(pairs):
            if (beneath(source, "lib/phronomy/multi_agent") and roles.get(source) != "domain_binding"
                    and (beneath(target, ENGINE) or roles.get(target) == "domain_binding")):
                violations.append({"kind": "coordination-selects-engine", "pair": (source, target)})
    for source in sorted(modules):
        denied = forbidden_roles.get(roles.get(source), set())
        if architecture.get("r8_unit6_contracts") and source in {"lib/phronomy/llm_adapter", "lib/phronomy/llm_adapter/backends"}:
            # C09 references C06 Schema/CallRequest only. Directory aggregation
            # also exposes Tool::Base -> Execution; the AST gate below separately
            # rejects C09 references to execution mechanisms or Tool::Base.
            denied = denied - {"execution_contracts"}
            for origin, target in pairs:
                if origin == source and roles.get(target) == "execution_contracts":
                    violations.append({"kind": "llm-direct-execution-dependency", "pair": (origin, target)})
        route = path_to(graph, source, lambda t: roles.get(t) in denied)
        if route:
            violations.append({"kind": "forbidden-responsibility-path", "source_role": roles.get(source), "path":route})
        if roles.get(source) == "mixed_backend":
            route = path_to(graph, source, lambda t: t in CLIENTS)
            if route:
                violations.append({"kind":"legacy-backend-reaches-client", "path":route})
    if architecture.get("r8_unit5_contracts"):
        for source in ["lib/phronomy/vector_store", "lib/phronomy/embeddings"]:
            route = path_to(graph, source, lambda t: t != source and roles.get(t) != "common")
            if route:
                violations.append({"kind": "independent-vector-contract-reaches-other-owner", "path": route})
        for source in ["lib/phronomy/documents/loader", "lib/phronomy/documents/splitter"]:
            route = path_to(graph, source, lambda t: roles.get(t) not in {"document_processing", "common"})
            if route:
                violations.append({"kind": "document-helper-reaches-domain-or-mechanism", "path": route})
    for impl, contract in IMPLEMENTATIONS.items():
        if impl in modules and not path_to(graph, impl, lambda t: t == contract):
            violations.append({"kind":"implementation-missing-contract-dependency", "implementation":impl,"contract":contract})
    # Content management uses neutral Storage, not a physical backend, Engine
    # or domain orchestration. Inspect transitive paths in the full Ruby + RBS graph.
    for source in sorted(modules):
        if roles.get(source) == "execution_contracts":
            route = path_to(graph, source, lambda t: roles.get(t) not in {"common", "execution_contracts"})
            if route:
                violations.append({"kind": "execution-contract-reaches-implementation", "path": route})
        if roles.get(source) == "execution_results":
            route = path_to(graph, source, lambda t: roles.get(t) not in {"common", "execution_contracts", "execution_results"})
            if route:
                violations.append({"kind": "execution-results-reaches-mechanism", "path": route})
        if architecture.get("execution_abstraction_revision") and source in CLIENTS and any(beneath(target, ENGINE) for a, target in pairs if a == source):
            violations.append({"kind": "async-client-directly-reaches-engine", "source": source})
        if roles.get(source) == "content_service":
            route = path_to(graph, source, lambda t: t != source and
                            t != "lib/phronomy/storage" and roles.get(t) != "common")
            if route:
                violations.append({"kind": "content-service-reaches-unrelated-responsibility", "path": route})
    settings = "lib/phronomy/configuration"
    for source in sorted(modules):
        if source == settings:
            route = path_to(graph, source, lambda t: roles.get(t) != "common")
            if route:
                violations.append({"kind": "runtime-settings-reaches-feature", "path": route})
    persistence_contract = "lib/phronomy/persistence/contract"
    persistence = "lib/phronomy/persistence"
    if architecture.get("persistence_framework_separated"):
        allowed = {persistence, "lib/phronomy/storage", "lib/phronomy/content_store"}
        route = path_to(graph, persistence, lambda t: t not in allowed and roles.get(t) != "common")
        if route:
            violations.append({"kind": "persistence-framework-reaches-domain-or-composition", "path": route})
        for source in ["lib/phronomy/storage", "lib/phronomy/storage/backends"]:
            route = path_to(graph, source, lambda t: beneath(t, persistence))
            if route:
                violations.append({"kind": "storage-reaches-persistence", "path": route})
    elif persistence_contract in modules:
        route = path_to(graph, persistence_contract, lambda t: roles.get(t) != "common")
        if route:
            violations.append({"kind": "persistence-contract-reaches-implementation", "path": route})
    if persistence_contract in modules or architecture.get("persistence_framework_separated"):
        # Domain operations consume their own record protocol and common
        # Persistence failures, never the raw Storage view/error SPI.
        domain_consumers = ["agent", "agent/execution", "agent/handoff", "agent/lifecycle",
                            "agent/recovery", "agent/recovery/recovery_coordinator",
                            "multi_agent", "workflow/execution"]
        for consumer in domain_consumers:
            pair = ("lib/phronomy/" + consumer, "lib/phronomy/storage")
            if pair in pairs:
                violations.append({"kind": "domain-consumer-reaches-raw-storage", "pair": pair})
    for source, prohibited in {
        "lib/phronomy/context": ("lib/phronomy/agent", "lib/phronomy/engine"),
        "lib/phronomy/tool": ("lib/phronomy/agent", "lib/phronomy/engine", "lib/phronomy/llm_adapter", "lib/phronomy/multi_agent"),
        "lib/phronomy/execution": ("lib/phronomy/engine", "lib/phronomy/tracing"),
        "lib/phronomy/execution/concurrency": ("lib/phronomy/engine", "lib/phronomy/tracing"),
    }.items():
        if source not in modules:
            continue
        route = path_to(graph, source, lambda t: any(beneath(t, root) for root in prohibited))
        if route:
            violations.append({"kind": "r8-domain-backward-dependency", "path": route})
    features = [f.replace("vector_store/embeddings", "embeddings") if architecture.get("r8_unit5_contracts") else f for f in policy["features"]]
    required=[]
    for feature in features:
        required.append("lib/phronomy/"+feature+"/async/async_client.rb")
    files = {
        "llm_adapter": ["llm_adapter/backends/ruby_llm.rb"],
        "vector_store": ["vector_store/backends/in_memory.rb", "vector_store/backends/pgvector.rb", "vector_store/backends/redis_search.rb"],
        "vector_store/embeddings": ["vector_store/embeddings/backends/ruby_llm_embeddings.rb"],
        "storage": ["content_store/stored_contents.rb"],
        "embeddings": ["embeddings/backends/ruby_llm_embeddings.rb"],
    }
    required += ["lib/phronomy/"+f for feature in features for f in files[feature]]
    for relative in required:
        if not (repo/relative).is_file():
            violations.append({"kind":"missing-phase-source","file":relative})
    if architecture.get("execution_abstraction_revision", 0) >= 2:
        violations.extend(abstraction_violations(repo))
    return {"phase":phase,"commit":audit["commit"],"passed":not violations,
            "remaining_legacy_pairs":sorted(actual),"rules_basis":"semantic responsibilities, independent of IDs and coordinates",
            "violations":violations,"limitations":["Static Ruby constants, literal requires and declared RBS type references", "Directory aggregation may overapproximate indirect paths; inspect member/file evidence", "Untyped injection, root-loader wiring and runtime/API compatibility require separate checks"]}


def graph_delta(baseline, current):
    def pairs(audit):
        return {(p["from"], p["to"]) for p in audit["module_pairs"]}
    before = pairs(baseline)
    after = {(p['from'], p['to']) for p in current['module_pairs'] if p['references'] or p['requires']}
    return {
        "baseline_commit": baseline["commit"],
        "source_commit": current["commit"],
        "added_pairs": sorted(after - before),
        "removed_pairs": sorted(before - after),
        "baseline_scc": [c for c in baseline["scc_all"] if len(c) > 1],
        "comparison_basis": "Ruby-only graphs (historical baseline has no RBS evidence)",
        "source_scc": [c for c in current.get("scc_ruby", current["scc_all"]) if len(c) > 1],
        "rbs_added_pairs": sorted(pairs(current) - after),
        "union_scc": [c for c in current["scc_all"] if len(c) > 1],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--phase", choices=PHASES, help="Default: tools/architecture/phase.json")
    parser.add_argument("--candidate", action="store_true", help="Mark an unpublished local snapshot and disable GitHub source links")
    args = parser.parse_args()
    if args.phase is None:
        args.phase = json.loads((HERE / "phase.json").read_text())["phase"]
    if args.phase not in PHASES:
        raise ValueError("Unknown phase in phase.json")
    repo, output = args.repository.resolve(), args.output.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use an empty output directory to avoid mixing source revisions")
    head = git(repo, "rev-parse", "HEAD")
    if git(repo, "status", "--porcelain", "--", "lib", "sig"):
        raise ValueError("Commit lib and sig changes before generating a source-linked SVG")
    version_text = (repo / "lib/phronomy/version.rb").read_text()
    match = re.search(r'VERSION\s*=\s*["\x27]([^"\x27]+)', version_text)
    if not match:
        raise ValueError("Cannot read VERSION from source")
    with tempfile.TemporaryDirectory(prefix="phronomy-phase-") as directory:
        work = Path(directory)
        analysis = work / "analysis"
        subprocess.run([sys.executable, str(HERE / "tools/analyze_dependencies.py"), str(repo), str(analysis)], check=True, stdout=subprocess.DEVNULL)
        audit = json.loads((analysis / "module_audit_scoped.json").read_text())
        if audit["commit"] != head or audit["source_changed"]:
            raise ValueError("Source changed during boundary analysis")
        report = check_boundaries(audit, args.phase, repo)
        if not report["passed"]:
            print(json.dumps(report, indent=2), file=sys.stderr)
            raise ValueError("Phase boundary check failed; no SVG generated")
        architecture_path = HERE / "config" / (args.phase + ".architecture.json")
        layout_path = HERE / "config" / (args.phase + ".layout.json")
        architecture = json.loads(architecture_path.read_text())
        architecture["project_title"] = "PHRONOMY " + match.group(1)
        config = work / "architecture.json"
        config.write_text(json.dumps(architecture, indent=2) + "\n")
        built = work / "built"
        subprocess.run([sys.executable, str(HERE / "tools/build_diagram.py"), str(repo), str(built), "--architecture", str(config), "--layout", str(layout_path), "--revision", args.phase + "-" + head[:8], *(["--candidate"] if args.candidate else [])], check=True, stdout=subprocess.DEVNULL)
        second = json.loads((built / "module_audit_scoped.json").read_text())
        if audit != second or git(repo, "rev-parse", "HEAD") != head:
            raise ValueError("Source changed between boundary analysis and drawing")
        baseline = json.loads((HERE / "evidence/baseline/module_audit_scoped.json").read_text())
        if baseline["commit"] != BASELINE_COMMIT:
            raise ValueError("Unexpected baseline evidence commit")
        write_triangles(triangles(audit, architecture, json.loads(layout_path.read_text())), built)
        (built / "boundary_validation.json").write_text(json.dumps(report, indent=2) + "\n")
        (built / "graph_delta.json").write_text(json.dumps(graph_delta(baseline, audit), indent=2) + "\n")
        (built / "architecture.json").write_text(config.read_text())
        provenance = {"source_commit": head, "source_tree": git(repo, "rev-parse", "HEAD^{tree}"), "phase": args.phase, "candidate": args.candidate,
                      "phase_file_sha256": hashlib.sha256((HERE / "phase.json").read_bytes()).hexdigest(),
                      "rbs_parser": {k: audit["rbs"][k] for k in ["parser", "version"]},
                      "configuration_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [architecture_path, layout_path, HERE / "config/rbs_owners.json"]},
                      "scripts_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__), *sorted((HERE / "tools").glob("*.py")), *sorted((HERE / "tools").glob("*.rb"))]}}
        (built / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        output.mkdir(parents=True, exist_ok=True)
        for file in sorted(built.iterdir()):
            (output / file.name).write_bytes(file.read_bytes())
    print(json.dumps({"phase": args.phase, "commit": head, "svg": str(output / "dependencies.svg"), "static_boundary_gate": "passed", "full_union_boundary_passed": report["passed"]}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
