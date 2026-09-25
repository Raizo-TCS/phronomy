# Architecture evidence and responsibility groups

The source graph comes from Ruby AST analysis. Configuration supplies module
IDs and responsibility groups; layout supplies positions. The measured diagram
restores the earlier B1-B6 horizontal bands, five topical columns and right-hand
support area. These display layers organize the view; boundary permissions
continue to depend on responsibilities, not coordinates or B/G numbers.

```sh
python3 -m venv tmp/architecture-venv
tmp/architecture-venv/bin/python -m pip install -r tools/architecture/tools/requirements.txt
tmp/architecture-venv/bin/python -m unittest discover -s tools/architecture/tests -v
tmp/architecture-venv/bin/python tools/architecture/refresh_diagram.py . tmp/architecture
```

Use an empty output directory and committed `lib` sources. The command never
stages, commits or modifies Ruby source. The repository's `phase.json` declares
the current phase (`storage`: P1/P2/P3/P4 complete). `--phase` can explicitly check another
phase during development; it cannot add absent modules or remove real edges.
New or missing directories, duplicate IDs, incomplete group membership and
forbidden responsibility paths fail the gate.

Outputs include the full SVG/matrix, all/scoped AST JSON, source fingerprints,
module-to-ID annotations, boundary results, graph/SCC differences from baseline,
and source/configuration/tool provenance. Directory paths can overapproximate
indirect dependencies; inspect the file references when reviewing a violation.
Dynamic injection, root-loader wiring, RBS and runtime behavior need Ruby tests
and review in addition to this gate.

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
The boundary gate always checks the full AST graph before presentation filtering.
With transparent nodes, paths end at box boundaries instead of exposing the
previous center-to-border segments. This changes neither group membership nor
dependency permission. Remove the target IDs to show those arrows again.
