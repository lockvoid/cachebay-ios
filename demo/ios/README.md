# HarryPotterDemo

iOS demo for [Cachebay](../..). Mirrors the [web demo](https://harrypotter.exp.lockvoid.com/) but uses the Swift runtime + SQLite persistence + WebSocket subscriptions.

## Prereqs

- Xcode 15+
- Node 18+ and [pnpm](https://pnpm.io)
- [Rust toolchain](https://rustup.rs) (the codegen CLI is Rust)
- `xcodegen` — `brew install xcodegen`

## Run

```sh
# terminal 1 — server
cd ../server
pnpm install
pnpm start                       # http://localhost:4000/graphql + ws

# terminal 2 — iOS
make all                         # builds Rust CLI, runs codegen, xcodegen project
open HarryPotterDemo.xcodeproj
```

Then run on any iOS simulator. The app talks to `http://127.0.0.1:4000/graphql`.

## What it demos

- **Relay connection**: `spells @connection(mode: "infinite", filters: ["filter"])` with live search + load-more pagination.
- **`watchFragment`**: Spell detail view live-updates when the list mutates the entity elsewhere.
- **Optimistic `addNode`**: creating a spell prepends instantly, commits with server data on success, reverts on failure.
- **Subscriptions**: `hogwartsTimeUpdated` ticks every second via `graphql-transport-ws` over WebSocket.
- **SQLite persistence**: kill and relaunch — the list renders from disk before the network refetch finishes.
