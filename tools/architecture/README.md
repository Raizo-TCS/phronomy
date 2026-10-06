## r8 unit 12 update

C01's generated subagent Tool derives directly from C06 Tool::Base, without
depending on the concrete Tools::Agent implementation. C06 owns asynchronous
Tool validation, errors and result limits; C01 retains child execution and
durable reconciliation. Orchestrator remains an Agent::Base subclass. AST and
Ruby/RBS graph gates prevent the concrete Tool dependency from returning.
C02 Workflow connections/durable children and broader Recovery review remain.
See `docs/architecture/r8-unit12.md`; earlier checkpoints below are historical.

## r8 unit 11 update

C04 no longer selects DefaultPolicy or constructs the concrete LLM AsyncClient.
Boot composition installs the Policy through the existing DSL. M88 selects the
LLM client and binds submission to the Agent's captured Runtime. No module or
public API is added. AST and Ruby/RBS graph gates guard these connections while
retaining lower-level restrictions. C01 Orchestrator inheritance, C02 Workflow
connections/durable children and broader semantic review remain. See
`docs/architecture/r8-unit11.md` for scope and acceptance evidence.

## r8 unit 10 update

C01 retains coordination admission and Team identity rules. Concrete Runtime
registration, lookup, validity checks and cancellation submission now belong to
M89/G63 multi_agent/runtime_binding through a private ExecutionEnvironment port.
The existing Engine shutdown participant protocol is unchanged. AST and graph
checks reject concrete Engine connections in MultiAgent domain files. Workflow
connections and broader dependency review remain; see `docs/architecture/r8-unit10.md`.

## r8 unit 9 update

C06's result decorators preserve application-defined stage ordering and repeated
registrations. Base's internal async-to-sync bridge passes an explicit bound
callable to ToolExecutor, avoiding duplicate transformation under custom async
super delegation. Explicit application calls keep their own transformations.
No new cross-domain dependency is introduced. See `docs/architecture/r8-unit9.md`.

## r8 unit 8 update

C04 Tool child progress now owns a single ordered transition definition and
entry operations. M88 also constructs Tool child sessions. M57 no longer
selects concrete Engine/FSM classes or the private Tool executor. C06 Operation
owns Tool dispatch/result adaptation and consumes C13's submitter protocol.
The gate covers Tool child source as well as parent progress. Other domains and
overall cycles remain; earlier checkpoints below are historical.

## r8 unit 6 update

C09 consolidates values, usage, failures and synchronous operation rules in
LLMAdapter. M47 is retired into M15 without reusing its ID. C06 is independent of
RubyLLM and owns Schema/CallRequest. AST rules reject SDK/Agent/Engine dependencies
inside these contracts and SDK types inside Agent. The measured Ruby/RBS graph
retains C09 -> C06 and the directory-level Tool -> Execution route; see
`docs/architecture/r8-unit6.md` for the exact overapproximation and supporting
standalone/value-only checks. FSM/Runtime connections remain unfinished.

## r8 unit 5 update

VectorStore and Embeddings own their common synchronous operations. Embeddings
is independent of VectorStore; document loaders and splitters belong to
Documents. The Ruby/RBS boundary gate rejects cross-contract and Engine paths
from these two common bases, and rejects document helpers depending on vector
storage or embeddings. Runtime submission remains in each AsyncClient.
The source diagram keeps unresolved dependencies in other domains visible.
See `docs/architecture/r8-unit5.md` for the implemented scope and remaining gates.

## r8 unit 4 update

Agent control/transfer and execution-change contracts no longer select MultiAgent
policy or routing. MultiAgent uses typed Agent public operations and its own
Handoff/subagent state; the AST guard rejects private Agent reads in those paths.
The common JSON value alias belongs to Common, and Handoff repository types belong
to MultiAgent. Actual source diagrams still display outstanding Runtime/Engine
coordination dependencies. See `docs/architecture/r8-unit4.md`.

## r8 unit 3 update

The source diagram removes `persistence/api`, `persistence/contract`,
`multi_agent/storage_contract`, and `workflow/storage_contract`. Common
Persistence is defined in `persistence/persistence.rb`; failures are consolidated
in `persistence/errors.rb`. Agent and Team store protocols are owned by their
domains, including their RBS declarations. The full Ruby/RBS gate rejects common
Persistence reaching domain implementations or composition. Targeted AST checks
also reject fixed record adapter selection in the admission/store framework and
Team access to Agent repositories, journal positions, and execution metadata.
Subagent/Handoff internal coordination dependencies remain visible and unresolved.

The sections below include earlier implementation checkpoints; their historical
module counts and removed paths do not override the current source diagram.

# Architecture evidence and responsibility groups

The source graph is the union of Ruby AST dependencies and declared RBS type
references resolved by the official RBS parser. Configuration supplies module
IDs and responsibility groups; layout supplies positions. The measured diagram
restores the earlier B1-B6 horizontal bands, five topical columns and right-hand
support area. These display layers organize the view; boundary permissions
continue to depend on responsibilities, not coordinates or B/G numbers.

```sh
bundle install
bundle exec rbs -I sig validate
python3 -m venv tmp/architecture-venv
tmp/architecture-venv/bin/python -m pip install -r tools/architecture/tools/requirements.txt
tmp/architecture-venv/bin/python -m unittest discover -s tools/architecture/tests -v
tmp/architecture-venv/bin/python tools/architecture/refresh_diagram.py . tmp/architecture
```

Use an empty output directory and committed `lib` and `sig` sources. The command never
stages, commits or modifies Ruby or RBS source. The repository's `phase.json` declares
the current phase (`storage`: P1/P2/P3/P4 complete). `--phase` can explicitly check another
phase during development; it cannot add absent modules or remove real edges.
New or missing directories, duplicate IDs, incomplete group membership and
forbidden responsibility paths fail the gate.

Outputs include the full SVG/matrix, all/scoped AST JSON, source fingerprints,
module-to-ID annotations, boundary results, graph/SCC differences from baseline,
and source/configuration/tool provenance. Directory paths can overapproximate
indirect dependencies; inspect the file references when reviewing a violation.
Untyped dynamic injection, root-loader wiring and runtime behavior need Ruby
tests and review in addition to this gate. Type references express declared
contracts, not proof of which injected concrete implementation executes.

For a committed but unpublished local candidate, use `--candidate`. This labels
the SVG as an unapplied candidate and disables GitHub links while preserving
module/source-line titles, matrix cells and full JSON evidence. After applying
and committing the changes, regenerate without this flag. CI does this for the
actual checkout SHA and uploads an artifact; no action writes back to the repo.
A source commit must not contain an SVG that purports to embed its own SHA.

`draw_target.py --output tmp/engine-responsibilities-target.svg` draws the scoped
responsibility concept with ContentStore over Storage and separate Execution
Contracts, Execution Services and Engine Internals. It retains
the individual module boxes and thin group frames. It is not the measured
diagram and is not proof that a candidate has been applied.

The analyzer and parser versions are preserved from the reviewed toolkit.
`evidence/baseline` records main 84668606 for comparison. The baseline is not
reused as current evidence: source is analyzed afresh for every run. The
`tools/` directory is excluded from the released Ruby gem.

## Layered display

Each phase layout lists `bands`, their five `columns`, and a separate `support`
list. Every actual module ID must appear exactly once. Existing domain modules
retain the reviewed display order. B4 contains Execution Services, Async Clients, separately grouped
Implementations, document processing, and backend directories whose separation
is still pending. B5 contains separated Backend Contracts, Execution Contracts and token-budget
rules beside Engine Internals. Later phases move a contract to B5 only
after its source responsibilities are split. B1-B6 are presentation metadata
only and never enter the architecture role annotations or boundary rules. The formatter also accepts
the previous `group_columns` layout for reproducing older display revisions.

Source analysis, group membership, dependency counts and the matrix are
independent of the chosen layout. Regeneration always uses the committed phase
and current source evidence, rather than restoring an older source graph.

## Group colors

Each phase layout defines `group_theme.palette` and the stable group-to-palette
mapping in `group_theme.groups`. Pastel group backgrounds retain the previous
diagram's subdued colors; module and caption panels are transparent, with the
individual module outlines retained.
The same group ID keeps its colors across phases. G14 Engine Internals uses blue, G46
Async Clients lavender, G47 Backend Contracts mint and G48 Implementations sand.
G58 Execution Contracts uses mint and G59 Execution Services lavender.
The refined candidate integrates neutral TaskResult and its implementation into
the existing Execution Contracts group (G58). The extra errors and Results
directories, M79/M80/M81 and G60 are retired. G61 Engine Concurrency remains
blue. Invocation controls and completion adaptation belong to Services in B4.
The boundary gate rejects Contracts reaching Services/Engine, Engine reaching
Services, and Concurrency reaching parent Engine/Services, including indirect
Ruby + RBS paths. A separate AST gate checks leaks of private scope and result
settlement into domain consumers. Dependency triangles are investigation
candidates, not automatically forbidden edges or layering rules.
Color does not express a layer, dependency permission or a unique namespace.
G57 Content Service uses teal and M10 moves to B3's persistence column. M73 is
retired after merging its implementation into M10; it is removed from current
nodes and the matrix. Historical phase/baseline evidence remains unchanged.
ContentStore is not a backend family. Its measured Storage dependency is kept;
the gate permits only neutral Storage and Common dependencies from the service,
and rejects reverse backend/Engine dependencies on it, including RBS-only paths.
Group backgrounds are painted behind all arrows, including muted common
dependencies. Module boxes, source evidence and matrix cells stay intact.

## Display filters

Every phase layout retains `presentation.transparent_text_panels: true` and
`presentation.hidden_incoming_targets: ["M33", "M41", "M44"]`. Hidden arrows
remain in the SVG with `display="none"`; metadata, links and the complete matrix
retain all measured edges. Counts distinguish measured pairs and visible arrows.
Boundary analysis always receives the full Ruby + RBS graph before presentation filtering.
With transparent nodes, paths end at box boundaries instead of exposing the
previous center-to-border segments. This changes neither group membership nor
dependency permission. Remove the target IDs to show those arrows again.

## RBS layout and evidence

Public gem signatures remain under `sig/`. Backend contracts, implementations
and clients use subdirectories corresponding to their Ruby responsibilities:
`sig/phronomy/llm_adapter/base.rbs`, `llm_adapter/backends/ruby_llm.rbs`,
`vector_store/async/async_client.rbs`, and so on. RBS imposes no one-file-per-class
requirement; other consolidated signatures remain supported. The internal LLM
AsyncClient signature is under `sig/_private/phronomy/llm_adapter/async/`.
RBS loads underscore directories with `-I sig` for development; gem library
loading excludes them, so this addition does not publish the internal API.
See the [RBS gem documentation](https://github.com/ruby/rbs/blob/master/docs/gem.md).

`extract_rbs.rb` uses `RBS::Environment.resolve_type_names` with the installed
Gemfile version (currently 4.1.x). It traverses nested method/block/proc types,
attributes, variables, generic bounds/defaults, aliases, inheritance, mixins and
module self types. Unknown types, unsupported AST nodes and missing ownership
fail rather than silently omitting dependencies. Core/external references are
retained separately and do not become Phronomy modules.

RBS declarations are attached to their actual Ruby declaration owners; singleton
members use their actual Ruby method definition when available. The RBS filename
is source evidence, not a synthetic module. `config/rbs_owners.json` assigns only
RBS-only interfaces/type aliases to existing responsibilities. It contains no
dependency arrows. In particular, `_CancellationSignal` belongs to neutral
common contracts, not the Engine's concrete CancellationToken. `untyped` values
and implicit receiver implementations are not guessed.

A directed directory pair is drawn once even when multiple sources support it.
SVG metadata and cell/arrow hover text preserve every evidence kind/file/line.
Matrix keys are C (Ruby constant), L (literal require), T (RBS type), and + (more
than one kind). The complete union drives directory SCCs and fan-in/out. Ruby
file SCCs keep their previous Ruby-only meaning; they are labelled accordingly.
Display filters never alter the audit, matrix or SCC calculation.

- `module_audit.json`: original unscoped Ruby AST evidence.
- `module_audit_ruby_scoped.json`: Ruby-only scoped graph for comparable history.
- `rbs_audit.json`: resolved RBS references, external references and ownership.
- `module_audit_scoped.json`: complete scoped Ruby + RBS union and evidence.
- `graph_delta.json`: Ruby-only comparison with the historic Ruby-only baseline,
  plus RBS-added pairs and the new union SCCs.
- `source_sha256.json`: every analyzed Ruby and RBS file, including `_private`.
- `provenance.json`: parser version, source commit/tree, scripts and configuration.

## Strict configuration boundary

Engine reads only the internal `RuntimeSettings` value object in
`lib/phronomy/configuration/`. It contains no Agent, LLM adapter, persistence or
concrete tracer class references. Application-facing `Configuration` and its
global/scoped accessors belong to `runtime_composition/`; they compose these
neutral settings with application options. Their public RBS signatures retain
the same types and follow the Ruby declaration owner.

The lazy provider is installed by application composition and returns only
`RuntimeSettings`. Reset and scoped restoration are resolved on every read;
Engine does not receive the application `Configuration` object.

The full Ruby + RBS union now must pass the boundary policy without exemptions.
The former two-reference RBS baseline has been removed. A new guard also rejects
any transitive path from neutral settings to a non-common responsibility.
The graph remains directory-based: application configuration and lifecycle
composition share a directory, so aggregating their references can join SCCs.
Use file/member evidence to distinguish this from an Engine-to-domain path.
See [ADR-060](../../docs/decisions/060-runtime-settings-and-application-configuration.md).

## Domain persistence failure boundary

G55 (M74, `persistence/`) contains the private raw-to-domain failure translator
and content repository. G56 (M75, `persistence/contract/`) contains independent
public Persistence failure classes. They retain the existing B1/B3 placement
conventions without assigning any boundary permission to a display band.

The complete Ruby + RBS gate rejects non-Common dependencies reachable from the
failure contract and rejects raw Storage references from the eight reviewed
Agent execution/lifecycle/Handoff/recovery, MultiAgent and Workflow execution
directories. Their dedicated Storage AsyncClient references remain permitted;
repository/codec dependencies on raw Storage retain their actual evidence.

The canonical `Phronomy::Persistence` declaration belongs to
`persistence/api/persistence.rb`, matching the real service definition. Namespace
reopenings in storage_boundary.rb or contract files do not move that ownership.
The analyzer regression checks the Ruby declaration owner, independent of RBS
filename; no type reference or measured edge is suppressed by this correction.

## r8 unit 1: Context, Tool and Execution

This is the first implementation unit of r8, not completion of the whole specification.
`phase.json` retains the older backend phase label `storage`; its P1-P5 numbers
are unrelated to the r8 Persistence design items. The `r8_unit1` member records
scope and remaining work. See [the implementation report](../../docs/architecture/r8-unit1.md).

G58 now owns `execution/` (M76) and `execution/concurrency/` (M77).
The former `execution_contract/` and `execution_services/` directories are removed.
TaskResult composition, controls and waiting use shared rules in this framework.
Pool/runtime/timer access belongs to `engine/execution_binding.rb`, installed
lazily by composition through the Execution backend protocol. Creating or
observing a settled result does not instantiate Runtime. Runnable tracing is
owned by `Tracing::Observation`; FSM-only values and receiver protocols belong
to Engine. Engine depends on Execution; Execution has no source or type
reference to Engine, Tracing or domain orchestration.

G25/M40 owns `context/`: policy execution, canonical input, validation, budget
and manifest handling. G06/M25 owns Tool definitions, authorization evaluation
and calling. Their Agent lifecycle consumers remain separate. The complete
Ruby/RBS gate checks direct and transitive reverse paths for these boundaries,
as well as the existing backend restrictions. RBS-only edges are tested too.

Agent, Workflow and MultiAgent still have mixed domain/mechanism and persistence
responsibilities. Existing measured cycles remain visible; passing this scoped
gate does not prove all domain contracts are acyclic or all triangle candidates
are acceptable. B/G positions remain presentation, not dependency permissions.

### Transitive dependency triangles (review aid)

`refresh_diagram.py` also writes `dependency_triangles.json` and `.csv`.
For every three distinct modules with M0→M1, M1→M2 and M0→M2, it preserves all
three edges' source evidence. Adjacent descending display bands are listed first,
then other descending bands, then other graph triangles. Sidebar modules and
incoming arrows hidden in the SVG are still included. RBS-only direct references
are marked separately; they are often legitimate return/input contracts.

A triangle is an investigation candidate, **not a failure**. Inspect M0's direct
use: an internal detail normally belongs behind M1, composition wiring may belong
in a composition owner, and an intentionally shared public contract can stay.
Absence of a triangle does not prove absence of leaks (dynamic dispatch and
module aggregation limit this heuristic). The narrow Ruby AST gate independently
protects already-corrected private scope access and result settlement in selected
consumers; it is not a whole-program architecture proof.

To inspect any existing audit without regenerating the SVG:

```sh
python3 tools/architecture/tools/find_dependency_triangles.py \
  OUTPUT/module_audit_scoped.json OUTPUT/architecture.json \
  tools/architecture/config/storage.layout.json OUTPUT
```

## r8 unit 2: parent reservation and Agent admission

`Persistence::Transaction` owns synchronous participation and commit status;
`Agent::Admission` owns acceptance; MultiAgent owns the reservation check.
The gate now rejects parent repository access from Agent admission and domain
selection inside the transaction framework. These targeted rules do not prove
that the remaining legacy facade or all domain dependencies are correct.
The existing display bands and hidden common arrows are preserved.
See [the implementation boundaries](../../docs/architecture/r8-unit2.md).
