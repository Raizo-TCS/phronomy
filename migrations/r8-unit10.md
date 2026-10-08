# Migrating to r8 unit 10

Apply after core d961fc742f6c4ea4d06dc89f20eedfeb49d04099 (unit 9).
This package changes core only. The unit 6 examples at
ed455c52018338f7c5a4c2948ae0d7db131aa090 require no source changes.

Public TeamCoordinator and HandoffRunner arguments and results are unchanged.
No database migration or application Registry registration is needed.
The existing registries remain MultiAgent-owned and preserve their rules.

| Internal use | Replacement |
| --- | --- |
| AdmissionRegistry.for(runtime) | The owning MultiAgent ExecutionEnvironment.admissions |
| TeamOwnershipRegistry.for(runtime) | The owning environment.ownership |
| TeamOwnershipRegistry.existing_for(runtime) | The selected environment.existing_ownership for lookup only |
| Team/Handoff Runtime.instance checks | The captured environment.current? |
| Team cancellation Execution.submit(runtime: ...) | The captured environment.submit(...) |
| Team persistence factory in runtime_composition/agent_defaults.rb | runtime_composition/multi_agent_defaults.rb |

Registry construction remains side-effect free. Tests of domain rules can use
Registry.new; tests of Runtime registration use MultiAgent::EngineEnvironment.
Removed private class methods have no aliases. Internal callers are updated
together. New connection classes are private APIs; public RBS signatures stay
unchanged. Ordinary require "phronomy" installs defaults lazily, without creating
global configuration, stores or a Runtime during loading.

The ZIP includes complete changed files, a strict-base applier, expected-tree
verification, a review patch, test evidence and rollback instructions. Run
--check, --apply and --verify in a new worktree, then --verify again after commit.
Use the existing stop/drain procedure when replacing running processes. This
change does not add in-flight cross-version compatibility or rollback of
external effects.

For examples verification, unset BUNDLE_GEMFILE before entering the examples
checkout and set PHRONOMY_PATH to the candidate core. Inspect and restore only
verification-generated lockfile/vendor changes; no examples commit is needed.
