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

`draw_target.py --output tmp/backend-target.svg` draws the scoped, unimplemented
end-state concept. It retains the individual white module boxes and thin group
frames. It is not the measured diagram and is not proof that P3/P4 are complete.

The analyzer and parser versions are preserved from the reviewed toolkit.
`evidence/baseline` records main 84668606 for comparison. The baseline is not
reused as current evidence: source is analyzed afresh for every run. The
`tools/` directory is excluded from the released Ruby gem.

## Layered display

Each phase layout lists `bands`, their five `columns`, and a separate `support`
list. Every actual module ID must appear exactly once. Existing domain modules
retain the reviewed display order. B4 contains Async Clients, separately grouped
Implementations, document processing, and backend directories whose separation
is still pending. B5 contains separated Backend Contracts and token-budget rules
beside the independent Engine group. Later phases move a contract to B5 only
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
The same group ID keeps its colors across phases. G14 Engine uses blue, G46
Async Clients lavender, G47 Backend Contracts mint and G48 Implementations sand.
Color does not express a layer, dependency permission or a unique namespace.
Group backgrounds are painted behind all arrows, including muted common
dependencies. Module boxes, source evidence and matrix cells stay intact.

## Display filters

Every phase layout retains `presentation.transparent_text_panels: true` and
`presentation.hidden_incoming_targets: ["M33", "M41", "M44"]`. Hidden arrows
remain in the SVG with `display="none"`; metadata, links and the complete matrix
retain all measured edges. Counts distinguish measured pairs and visible arrows.
Boundary analysis always receives the full Ruby + RBS graph before presentation filtering.
The regression gate records two pre-existing Configuration type references as
explicit debt; the full-union report and SVG still include them (see below).
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
