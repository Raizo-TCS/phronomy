# ADR-037: Common Definition Ownership

## Status

Accepted on the architecture refactoring branch.

## Context

`lib/phronomy.rb` combines the application loading entry point with shared
exception definitions and global configuration. Internal consumers of the
base `Phronomy::Error` therefore refer back to the entry point even though
they do not explicitly require it.

The shared base exception has no dependency on feature implementations. It
belongs to a common definition group. An `errors/` group would not convey the
distinction between general definitions and feature-owned exception contracts.
The same distinction applies to definitions other than exceptions.

## Decision

1. Use `lib/phronomy/common/` for general definitions shared across the
   framework that do not belong to a particular feature. These definitions
   must not depend on concrete Agent, Workflow, Runtime, or other feature
   implementations. Multiple consumers alone do not establish common ownership.
2. Move only the base `Phronomy::Error < StandardError` definition from the
   entry point to `common/error.rb`. Name files after their responsibility;
   do not introduce an unbounded `common/common.rb` collection.
3. Collapse `common/` with Zeitwerk to retain `Phronomy::Error` as its canonical
   name. Do not introduce a second class, alias, or `Phronomy::Common` namespace.
   Ordinary application loading remains `require "phronomy"`.
4. Keep existing subclass definitions, inheritance, constructors, and rescue
   behavior unchanged. Inheriting from `Phronomy::Error` does not require a
   feature-owned exception to live in `common/`.
5. Keep the common base independent of entry-point loading. Reading its
   implementation file in isolation must not initialize the full framework.
   This is an internal architecture check, not a new public partial-loading API.

## Consequences and limits

Internal references to the shared base resolve to its common definition rather
than to the loading entry point. The application-facing constant and signatures
remain unchanged. No new explicit require of the application entry point is
introduced.

Other exceptions still defined in the entry point, global configuration, and
the mixed root implementation group need separate ownership reviews. This
single extraction does not establish that all file or directory cycles have
been eliminated.

## Verification obligations

Verify isolated base-definition loading, ordinary application loading, and eager
loading. Check ordinary and preloaded-base initialization orders, canonical
constant identity, representative subclass hierarchies, and catching a domain
exception with `rescue Phronomy::Error`. Preserve the public API snapshot and
RBS signatures. Compare dependency targets against the applied baseline and
report remaining entry-point references separately.
