# R8 unit20 migration

Apply to unit19 core commit `07b78c90ef6072f66fecb04ea6891eda50493546`.
No examples source change or data migration is required.

Metrics.snapshot, Diagnostics.snapshot and Diagnostics.dump keep their arguments,
metric keys, numeric values and output format. They no longer initialize execution
resources and remain usable while the default Runtime is stopping or stopped.

Before resource initialization, the corresponding values are zero. In particular,
offload_pool_size is zero until the default pool exists. Previously a snapshot
created the pool and reported its configured capacity. Do not use monitoring as
an implicit warmup. Normal execution still initializes the resources it needs.

For an existing pool, offload_pool_size remains its configured capacity after
shutdown; use the shutdown result to assess cleanup, not this metric. Retained
counters remain readable until default Runtime reset. After reset, observations
return zero until new resources are initialized. Named pools are not aggregated,
and simultaneous consistency across independently sampled counters is not added.

Unit19 stopping deadlines, completion judgment and cached-result behavior remain
unchanged. No public invocation API or persistence format changes. Reverting this
unit needs no data rollback but restores observation-triggered initialization and
shutdown-time diagnostic errors.
