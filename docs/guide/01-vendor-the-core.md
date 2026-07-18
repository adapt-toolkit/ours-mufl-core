# 01 · Vendor the core

Your application never copies protocol code — it pins the core as a **git submodule**
so the exact protocol revision you compiled against is recorded in your repo. This is
how every ours.network client consumes the core (the
[README](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/README.md) documents
the same one-liner).

**Prereqs:**

- `git` installed.
- Network access to `github.com` (or a local mirror of this repo).

**Steps:**

1. Create your application repo:

   ```sh
   mkdir my-app && cd my-app
   git init
   ```

2. Add the core as a submodule under `mufl_code/core`. The `mufl_code/` directory is
   your packet's compile root; the core **must** land in a `core/` subfolder of it,
   because that is where your `config.mufl` will look for it
   (see [02 · Configure & compile](./02-configure-and-compile.md)):

   ```sh
   git submodule add https://github.com/adapt-toolkit/ours-mufl-core.git mufl_code/core
   ```

   (SSH form: `git@github.com:adapt-toolkit/ours-mufl-core.git`.)

When cloning your app later, pull the pinned core with `git submodule update --init`.

**Verify:**

```sh
ls mufl_code/core/*.mm
git submodule status
```

Success markers:

- `ls` lists the seven protocol libraries, ending
  `mufl_code/core/a2a_protocol.mm` … `mufl_code/core/version.mm`.
- `git submodule status` prints one line: a commit hash followed by
  `mufl_code/core`.

Next: [02 · Configure & compile](./02-configure-and-compile.md).
