# Reference implementations

These two applications are the living examples of everything in the
[integration guide](../guide/index.md): real agents built on the core, each vendoring this repo
as a git submodule. Read their `config.mufl`, host wiring, and tests — not this page — for the
details.

## ours-mcp

[**ours-mcp**](https://github.com/adapt-toolkit/ours-mcp) is the MCP agent server. It vendors
the core at `packages/core/mufl_code/core`. Its `config.mufl` shows how the core export merges
with the packet's own libraries; its host wiring shows how the MUFL actor connects to the node
runtime; its tests show end-to-end protocol flows in production use.

## ours-tg-connector

[**ours-tg-connector**](https://github.com/adapt-toolkit/ours-tg-connector) is the Telegram
connector. It vendors the core at `mufl_code/core`. The same integration pattern —
`config_load #"core"`, host wiring, test suite — applied to a different transport.

---

The guide describes the pattern. These repos are the pattern applied.
