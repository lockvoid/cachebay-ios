# HarryPotterDemo — GraphQL server

Tiny Node + Apollo Server backing the iOS demo. Mirrors the schema used by the [web demo](https://harrypotter.exp.lockvoid.com/) so the same `cachebay-cli` codegen output works for both clients.

## Run

```sh
pnpm install
pnpm start          # http://localhost:4000/graphql + ws://localhost:4000/graphql
```

The iOS demo expects this server on `:4000`. Start it before launching the simulator app.

## Schema

Authoritative source: [`schema.graphql`](./schema.graphql). The iOS codegen reads this file via `cachebay-cli introspect` (run from `demo/ios/Makefile`).

## Seed data

`data/harrypotter.db` is a small SQLite snapshot — characters, spells, houses — committed to the repo so the demo runs without an external dataset.

To regenerate from scratch (the seed script lives in `src/seed.ts`):

```sh
rm -f data/harrypotter.db
pnpm seed           # populates a fresh harrypotter.db
```

## What's served

- `Query.spells(filter:, first:, after:)` — Relay-style connection with cursor pagination, used by the iOS demo's home screen.
- `Query.spell(id:)` — single-spell lookup.
- `Mutation.createSpell` — drives the optimistic-add flow.
- `Subscription.hogwartsTimeUpdated` — emits a tick every second over `graphql-transport-ws`.

## Ports / endpoints

| Endpoint                       | Purpose                       |
| ------------------------------ | ----------------------------- |
| `http://localhost:4000/graphql` | HTTP query/mutation endpoint |
| `ws://localhost:4000/graphql`   | WebSocket subscription endpoint |

Override the listen port with `PORT=4242 pnpm start` if `:4000` is taken.
