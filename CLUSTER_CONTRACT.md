# `core.cluster` — capability verb contract (core 2.3)

`core.cluster` promotes cluster / subagent management from private
`a2a_messaging` plumbing to a **first-class, app-reusable protocol capability**.
Any root-managing app (the messenger today, a telegram proxy later) advertises
the same generic surface: child/subagent lifecycle, per-child monitoring
authorization, the host-local contact book, and child↔contact plus
cross-cluster introductions.

This is a **documentation** contract. Verbs stay convention — the wire carries
opaque `$verb` / `$args` strings in `control_envelope_t`, and `dispatch()` routes
by `$cap` only (see `a2a_capabilities.mm`). Reserving `core.cluster` adds **one
constant** (`cap_cluster`) plus this contract; there is **no wire/type/dispatch
change**. An app implements the capability by wiring a handler under
`cap_cluster` in `a2a_capabilities::init`'s `$handlers` map and listing it in
`describe()`; gate it with `self_supports(cap_cluster)`, exactly as `core.connect`
is gated at `a2a_messaging.mm:~1013`.

## Advertising `core.cluster` ≠ having a manageable cluster

`describe()` is static/shared, so **every** identity that ships this capability
advertises `core.cluster` in its manifest — **including leaf children that manage
no children of their own**. Advertisement means "I speak the verbs," not "I have
a cluster to manage."

This is benign for the reference messenger (only a bound root surfaces the
Cluster tab), but it is a **false positive** for a generic consumer such as a
telegram-proxy that keys UI off capability presence alone. Therefore:

> A generic consumer **MUST** confirm an actual cluster via **`child.list`**
> before offering `child.create` / `child.remove` (or any management UI). An
> **empty list = no manageable cluster** — treat the node as a participant, not a
> root, and do not present lifecycle controls.

(Until tiered authz lands, `child.list` is also the cheapest capability probe: it
is read-only and side-effect-free.)

## Naming / back-compat

Existing wire verb names are **kept as-is — no hard rename.** `core.cluster` is
the documented umbrella; `app.agents` remains a recognized **alias** so current
clients keep working. New clients SHOULD advertise/route `core.cluster`.

## Verb → reference handler / composition → wire alias

Verified against the real reference-host handlers (critic R7). **CamelCase**
handlers (`provisionIdentity`, `delegateRole`, `deleteIdentityCompletely`,
`setAgentMonitoring`, `connect_sibling`, `sign_monitoring_auth`) are
reference-host (**ours-mcp daemon**) composites — **not** single core
transactions. **snake_case** names are core `a2a_messaging` transactions.
`core.cluster` blesses the **verb surface**; the consuming app/daemon owns the
composition.

| `core.cluster` verb | reference handler / composition | current wire alias |
|---|---|---|
| `child.create` | `provisionIdentity` + `set_my_bio` + `delegateRole` + best-effort `enroll_delegated_node` | `create_agent` |
| `child.list` | `list_contact_roots` / `list_contacts` (cluster filter) | `list_agents` |
| `child.set_bio` | `set_my_bio` (child-scoped role label) | `update_role` |
| `child.remove` | `deleteIdentityCompletely` — **FULL teardown** (packet / disk / contact-book / binding). **Destructive.** | `remove_agent` |
| `child.set_monitoring` | `setAgentMonitoring` = `connect_sibling` + `sign_monitoring_auth` (root) + `set_monitoring` (role) | `set_monitoring` |
| `contact.list` | `list_contacts` | — (host-local book) |
| `contact.add` | `generate_invite` — returns an invite blob the caller redeems | `contact_agent` |
| `contact.remove` | `remove_contact` | — (host-local book) |
| `introduce.child_to_contact` | `introduce` | — (1:1 introduction) |
| `introduce.cross_cluster` | `introduce_to_group` | — (cluster fan-out) |

> Note the deliberate asymmetry: **`child.remove`** is `deleteIdentityCompletely`
> (irreversibly tears the child down), whereas **`contact.remove`** is the much
> narrower `remove_contact` (drops one host-local contact edge). Do not conflate
> them.

`$args` shape per verb stays opaque JSON the app's handler interprets (same model
as `core.configuration`'s `$params`). The verbs above are the documented contract;
the handler is free to enqueue vs. process in-packet per the dispatch model.

## Guardrails — mechanisms, not policy (critic R6-3 / R6-5)

`core.cluster` promotes **mechanisms**, never **policy**. Every policy knob is an
**app parameter**. These are stated as honest **TARGETs / obligations**, not as
behavior that is already in place — the wire is neutral and the app owns the
dangerous choices.

- **`local_auto_accept` — RECOMMENDED safe default `false`.** The protocol-safe
  posture is to **queue introductions and local contact-book joins for operator
  approval**. **Current state:** the reference host **ours-mcp defaults
  `TRUE`** (`index.ts:1496,1541`). Flipping it to `false` is a **tracked
  obligation, not yet implemented** — do not document `false` as the current
  behavior.
- **Monitoring (`child.set_monitoring`) — child-visible notice is a TARGET.**
  Authorizing per-child monitoring **SHOULD** surface a **child-visible notice**.
  **Current state:** the code stores the root-signed `monitoring_auth` with **no
  notice**; surfacing it is an **obligation on the consuming app**. (Note: this
  per-child path — `setAgentMonitoring` = `connect_sibling` +
  `sign_monitoring_auth` + `set_monitoring` — is distinct from the one-time CP
  proxy bind `bind_monitoring_proxy`, i.e. the `set_proxy_pending` /
  `verify_proxy_code` / `disable_monitoring` 6-digit ceremony.)
- **`child.remove` — destructive, MUST be operator-confirmed.** It maps to
  `deleteIdentityCompletely` (full packet/disk/contact-book/binding teardown).
  **Current state:** the reference frontend (messenger `AgentNode`) implements a
  `confirm()` dialog before invoking it. Any other consumer carries the same
  obligation.

Core provides the verbs and the underlying transactions; the safe behavior above
is the app's responsibility, and the gaps called out are tracked obligations.

## Roadmap — tiered authorization (not yet enforced)

A future revision introduces tiered authz over these verbs:

```
observe  <  manage  <  create  <  destroy
child.list/contact.list     -> observe
child.set_bio/set_monitoring,
contact.add/remove, introduce.*-> manage
child.create                -> create
child.remove                -> destroy
```

Today the **app** gates verbs (and SHOULD apply the guardrails above). Core does
not yet enforce tiers; this section records the intended direction so app gating
can be written forward-compatibly.
