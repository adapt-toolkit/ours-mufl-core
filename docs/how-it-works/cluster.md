# Cluster

The `core.cluster` capability, defined in `a2a_cluster.mm`, gives a root node a
uniform surface for child/subagent lifecycle, per-child monitoring authorization,
the host-local contact book, and introductions between children and contacts.
The authz chokepoint in `a2a_capabilities::dispatch` gates every verb — handlers
run only after it clears.

Source: [`a2a_cluster.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_cluster.mm).

## Registry

The root packet holds a `cluster_members` map (keyed by container id) of
`member_t` rows. Each row tracks the child's name, role id, bio, persona,
current monitoring state, and advertised capability ids. The registry is a
projection of host truth: `reconcile` runs on boot and on a periodic schedule to
add children the host knows about but the registry doesn't, and to drop members
the host has removed.

```mufl
metadef member_t: ($cid -> global_id, $role_id -> str, $name -> str,
                   $bio -> str, $persona -> str, $monitoring -> str, $caps -> str[]).
```

## Lifecycle verbs

The `cluster_handler` function switches on the `$verb` field of each inbound
`control_envelope_t` and dispatches to the appropriate handler. The authorized
bare verb names (as they appear on the wire and in `control_auth_class`) are:

| Verb | Effect |
|---|---|
| `list` | Returns the current `cluster_members` registry. |
| `set_bio` | Updates the bio field for a child in the registry (registry-only, no host op). |
| `set_persona` | Updates the persona field for a child in the registry (registry-only, no host op). |
| `set_monitoring` | Emits a `host_set_child_monitoring` notify-action; confirmed by `confirm_child_monitoring`. |
| `create` | Emits a `host_provision_child` notify-action; the daemon provisions the child packet and calls back `register_provisioned_child`. |
| `remove` | Emits a `host_destroy_child` notify-action; confirmed by `confirm_child_destroyed`. |
| `contact` | Emits a `host_mint_child_invite` notify-action; the daemon runs `generate_invite` inside the child packet and calls back `register_child_invite`. |
| `introduce` | Composes `a2a_messaging::emit_pair` to introduce two established contacts to each other. |

For the full verb surface see [`a2a_cluster.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_cluster.mm).

Create and remove are asynchronous: the handler stores a pending-req (keyed by a
monotonic handle) and immediately acknowledges `{pending: true}`. The matching
host callback consumes the pending-req atomically and routes the final response to
the stored controller.

## Per-child monitoring authorization

`set_monitoring` derives the control-plane identity from the root's own
ceremony-pinned `monitoring_proxy` — never from the request args. The root must
be bound to a cluster control plane before enabling monitoring for any child.
Disabling does not require a bound CP; it clears the child's proxy immediately.

## Cross-cluster introductions

The `introduce` verb accepts two contact references (`$peer_a`, `$peer_b`) and
emits a pair of introduction messages via `a2a_messaging::emit_pair`. Both peers
must already be established contacts with stored address documents. The
`core.connect` capability exposes the same `introduce` verb (via
`connect_handler`) for peer-to-peer introduction without cluster context.

See [Capabilities & control](./capabilities-and-control.md) for the envelope and
dispatch model that gates every verb above.
