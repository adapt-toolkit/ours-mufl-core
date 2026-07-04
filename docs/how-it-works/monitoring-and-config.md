# Monitoring & config

Monitoring and configuration state is split across two libraries by where the
hidden gate state lives: `a2a_messaging.mm` owns the node-side gate and copy
generation; `a2a_monitoring.mm` owns the control-plane receiver.

Sources:
[`a2a_messaging.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_messaging.mm),
[`a2a_monitoring.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_monitoring.mm).

## Node side: forced copies

The `monitoring_proxy` field in `a2a_messaging` is declared `hidden`. That means
only code inside `a2a_messaging` can write it — an app or any other loading
library cannot assign `monitoring_proxy -> NIL` to suppress copies. The
`monitor_copy_actions` function gates every outbound and inbound message on this
field:

```mufl
fn monitor_copy_actions (direction: str, peer_cid: global_id, date: time, body: str) -> transaction::action::type[]
```

If `monitoring_proxy` is `NIL`, the function returns an empty action list and
no copy is sent. If it is set, the function appends an encrypted send to the
bound control plane on every message. The copy rides a distinct transaction
(`receive_monitoring_copy_tx`) so the control plane can distinguish it from
regular traffic.

## Bind ceremony

`set_proxy_pending` and `verify_proxy_code` in `a2a_messaging` implement the
6-digit bind ceremony that sets `monitoring_proxy`. They live in this library
— not in `a2a_monitoring` — precisely because `monitoring_proxy` is hidden here.
The ceremony is time-limited (300 seconds), attempt-limited (3 tries), and
requires code possession. Once verified, `monitoring_proxy` is set and copy
generation begins immediately.

Disable (`core.monitoring / disable` verb) requires the sender to be the bound
control plane; it clears `monitoring_proxy` so copy generation stops.

## Control-plane side: receiving copies

`a2a_monitoring.mm` is the CP-side library. It touches no gate state — it only
validates that the sender is a known contact and hands the copy to the app's
storage hook:

```mufl
trn receive_monitoring_copy args: any
```

The app wires the `$on_monitoring_copy_received` hook at init. Storage is
entirely app-side; the core handles wire validation and contact checks.

## Configuration

App configuration (`core.configuration`) is stored as an opaque string
(`app_config`) in `a2a_messaging`, also `hidden`. The bound control plane writes
it via `set_app_config` and reads it via `get_app_config`. The `authorize_control`
function in `a2a_messaging` enforces that only the bound control plane (the same
identity that passed the monitoring ceremony) may call these transactions — the
configuration and monitoring authorities are the same party.

The `$params` field in a `capability_t` descriptor carries the opaque config
schema for a frontend to render; the core stores only the raw blob and never
interprets it.

See [Capabilities & control](./capabilities-and-control.md) for the dispatch and
authz model, and [Cluster](./cluster.md) for per-child monitoring authorization.
