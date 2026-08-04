# GNOME Wayland Reload UX Contract

This reference governs decisions that cross reload boundaries. `SKILL.md`
remains the invoked workflow authority.

## Phase transitions

| Phase | Required evidence | Legal next state |
|---|---|---|
| Classify | Changed artifact and desired outcome known | Inspect |
| Inspect | Session, Shell version, UUID, source, and state known | Choose |
| Choose | Smallest effective refresh boundary selected | Execute or ask |
| Execute | One authorized mutation performed | Verify |
| Verify | Installed, runtime, and behavioral evidence collected | Complete or recover |
| Recover | Failure classified and prior state understood | Inspect through another boundary |
| Complete | Requested behavior proved | Receipt |

Documentation or matching file hashes alone never prove that edited JavaScript
is running.

## Assumptions and questions

Infer the named UUID when exactly one target is evident, preserve the host
session, prefer the smallest reversible boundary, and keep host and nested
session buses distinct.

Ask when target scope is ambiguous, when enabling a previously disabled
extension changes user state, when private host internals are proposed, or when
a real logout/login is required. Use one question per decision and never more
than three.

## Decision ownership

Recommend one refresh path. Mention another only when it changes isolation,
risk, authorization, or whether edited bytes can actually load.

## Mutation boundaries

- **Live setting:** observe the reaction before cycling anything.
- **Lifecycle cycle:** disable and enable one already-enabled extension.
- **Preferences process:** close and reopen the separate `gjs` process.
- **Schema consumer:** compile schemas and restart only the consumer.
- **Nested Shell:** launch a fresh disposable GJS process in a window.
- **Guarded host hot-swap:** private, top-level-only, best-effort rollback.
- **Host logout/login:** ends the graphical session and requires explicit
  authorization.

Never silently promote a failed low-risk boundary into a higher-risk one.

## Failure budget and recovery

After one failed boundary, inspect fresh state and logs. After a second failure
at the same boundary, change strategy. A partial `enable()` or hot-swap requires
best-effort cleanup before another attempt. A later successful check does not
erase an unexplained earlier failure.

## Proof ladder

Completion requires all three:

1. **Installed artifact:** the intended bytes and metadata are in the active
   extension location.
2. **Runtime evidence:** fresh process or import evidence, `ACTIVE` state, and
   relevant journal output.
3. **Observable behavior:** the changed UI, behavior, or unique diagnostic
   marker is visible across enough time to catch periodic resets.

## Progress and receipt

For longer work, report the active phase at the start, on strategy change, and
when user action is required. Finish with the selected boundary, exact change,
proof, recovery or rollback, remaining uncertainty, and one meaningful next
action.

## Honest boundary

A nested Shell is disposable but not sandboxed. Looking Glass hot-swap uses
private internals. The skill can refuse unsafe host-restart folklore; it cannot
make an in-process Wayland compositor restart safe.
