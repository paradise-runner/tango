# Tango

<img src="tango.png" alt="Tango logo" width="180" />

Tango is a local agent orchestration system that works with your existing ticketing and forge platform to help you get more done with your existing tools.

## What Tango Is

Tango is an orchestration system for AI-assisted software work. It helps you:

- keep track of what the agent is working on;
- connect work to the right codebase;
- preserve progress between runs;
- pause for human review before anything is merged;
- see the current state of work in one place.

Tango runs locally and is designed around the tools you already use rather than requiring every repository to adopt a special workflow file.

## Setup

Tango is a Gleam application targeting Erlang. To work on it locally you need:

- Erlang/OTP
- Gleam
- `mise` if you want to use the repo's documented commands verbatim

Clone the repository, install dependencies, and verify the project builds:

```sh
mise exec gleam@latest -- gleam deps download
mise exec gleam@latest -- gleam check
mise exec gleam@latest -- gleam test
mise exec gleam@latest -- gleam format --check src test
```

If you already have `gleam` on your `PATH`, the equivalent commands are:

```sh
gleam deps download
gleam check
gleam test
gleam format --check src test
```

Initialize Tango's local state before using the CLI:

```sh
mise exec gleam@latest -- gleam run -- init
```

By default that creates state under `~/.tango` and writes `config.toml` there.
For an isolated development state directory, set `TANGO_STATE_DIR` first:

```sh
export TANGO_STATE_DIR="$PWD/.tango-dev"
mise exec gleam@latest -- gleam run -- init
```

You can also override the default operator identifier with `TANGO_OPERATOR_ID`.
Once initialized, inspect the available commands with:

```sh
mise exec gleam@latest -- gleam run -- help
```

## Usage

The shortest path from a new ticket to `Done` looks like this:

1. Install independent ticket-system and forge capabilities through Tango, then
   combine them in a capability profile:

```sh
mise exec gleam@latest -- gleam run -- capability install ticket-system github
mise exec gleam@latest -- gleam run -- capability install forge github
mise exec gleam@latest -- gleam run -- capability profile create default \
  --ticket-system github \
  --forge github
```

Ticket-system installation configures a dedicated issue-management skill and
Tango lifecycle label identifiers. Forge installation configures a separate
pull-request and merge skill. They may use the same CLI, but they are selected
independently so future non-forge ticket systems can be combined with either
forge.

Use the normal install mode unless you intentionally manage the provider CLI
yourself. It verifies the configured CLI, installs it through a supported
operator-approved package manager when possible, and fails clearly rather than
leaving a partial capability. `--skill-only` records the skill and expected
command only; `tango run` will still exit if that command is not available.

2. Automatch and validate the ticket-system status map for the repository
   before creating tickets:

```sh
mise exec gleam@latest -- gleam run -- ticket-system status-map github automatch \
  --repo paradise-runner/tango
mise exec gleam@latest -- gleam run -- ticket-system status-map github validate \
  --repo paradise-runner/tango
```

Tango uses this map to translate its lifecycle states, such as `Done`, into the
ticket system's stable status or label identifiers. `automatch` is the easy
mode for new repositories: it discovers provider statuses, fills every
unambiguous lifecycle match it recognizes, and leaves validation required so you
can confirm the result.

If automatch or validation reports ambiguous or missing roles, inspect the
current map and available provider statuses:

```sh
mise exec gleam@latest -- gleam run -- ticket-system status-map github show
mise exec gleam@latest -- gleam run -- ticket-system status-map github discover \
  --repo paradise-runner/tango
```

Then update the missing role with the stable provider identifier and validate
again:

```sh
mise exec gleam@latest -- gleam run -- ticket-system status-map github set \
  --role done \
  --status-id closed
mise exec gleam@latest -- gleam run -- ticket-system status-map github validate \
  --repo paradise-runner/tango
```

3. Create and queue the ticket in Tango. Repository values must be GitHub
   `owner/repo` shorthand or full Git clone URLs; `casa` creates the isolated
   ticket workspace used by the agent.

```sh
mise exec gleam@latest -- gleam run -- ticket create \
  --repo paradise-runner/tango \
  --ticket-ref https://github.com/paradise-runner/tango/issues/42 \
  --ticket-system github \
  --forge github \
  --capability-profile default \
  --queue
```

4. Run the orchestrator and watch progress:

```sh
mise exec gleam@latest -- gleam run -- run
```

Startup preflights the local tools the runtime needs before it claims work:
`codex`, `casa`, and every configured ticket-system or forge CLI. If a
provider CLI such as `gh` or `fj` is missing, install it with
`tango capability install ...` instead of editing `config.toml` by hand. If
`codex` or `casa` is missing, install that runtime command or update the
matching `[agent.codex]` or `[workspace.aicasa]` command in `config.toml`.

In a second terminal you can inspect the current state:

```sh
mise exec gleam@latest -- gleam run -- status
mise exec gleam@latest -- gleam run -- dashboard
mise exec gleam@latest -- gleam run -- ticket show <ticket-id>
mise exec gleam@latest -- gleam run -- review list
```

5. When the ticket reaches human review, inspect the generated work and approve merge:

```sh
mise exec gleam@latest -- gleam run -- review show <ticket-id>
mise exec gleam@latest -- gleam run -- review merge <ticket-id>
```

6. Keep `tango run` active until the merge worker finishes and the ticket reaches `Done`. Confirm with:

```sh
mise exec gleam@latest -- gleam run -- ticket show <ticket-id>
```

If the agent or merge worker blocks, Tango records that state durably. Fix the external issue, then resume with:

```sh
mise exec gleam@latest -- gleam run -- ticket unblock <ticket-id>
mise exec gleam@latest -- gleam run -- ticket queue <ticket-id>
```

## How It Feels To Use

The intended experience is straightforward:

1. You add a ticket or work item.
2. You tell Tango which repository or repositories are involved.
3. Tango prepares a workspace and starts the agent work.
4. The work moves through research, planning, and implementation.
5. A human reviews the result.
6. Only after that approval does Tango move the work toward merge.

That gives you automation where it helps, and a real approval gate where it matters.

## What Tango Does Not Try To Be

Tango is not a replacement for your source control host, ticket tracker, or CI system.

It is also not a cloud control plane. The project is built around local execution, local state, and operator-controlled approvals.

## Current State

Tango is still early-stage software. The core idea and workflow are in place, but the project is being developed in the open and should be treated as an evolving tool rather than a finished product.
