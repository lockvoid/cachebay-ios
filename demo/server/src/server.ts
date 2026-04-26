// Thin GraphQL server for the Harry Potter demo.
// - HTTP via graphql-yoga at POST /graphql
// - Subscriptions via graphql-ws at WS /graphql (graphql-transport-ws protocol)
// - Backing store: better-sqlite3 on the seeded harrypotter.db.

import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { DatabaseSync } from "node:sqlite";
import { useServer } from "graphql-ws/lib/use/ws";
import { makeExecutableSchema } from "@graphql-tools/schema";
import { createYoga, createPubSub } from "graphql-yoga";
import { WebSocketServer } from "ws";

const __dirname = dirname(fileURLToPath(import.meta.url));
const typeDefs = readFileSync(resolve(__dirname, "../schema.graphql"), "utf8");
const dbPath = process.env.CACHEBAY_DEMO_DB ?? resolve(__dirname, "../data/harrypotter.db");
const port = Number(process.env.PORT ?? 4000);

const db = new DatabaseSync(dbPath);
const pubSub = createPubSub<{ hogwartsTimeUpdated: [{ id: string; time: string }] }>();

const delay = (ms: number) => new Promise(r => setTimeout(r, ms));

// Push a time update every second so the iOS demo has a live signal.
setInterval(() => {
    pubSub.publish("hogwartsTimeUpdated", { id: "1", time: new Date().toISOString() });
}, 1000);

type Spell = {
    id: number;
    name: string;
    category: string;
    creator: string | null;
    effect: string;
    light: string | null;
    imageUrl: string | null;
    wikiUrl: string | null;
};

const resolvers = {
    Query: {
        spell: async (_: unknown, { id }: { id: string }) => {
            await delay(50);
            return db.prepare("SELECT * FROM spells WHERE id = ?").get(id);
        },
        spells: async (_: unknown, args: { first?: number; after?: string; filter?: { query?: string; sort?: string } }) => {
            await delay(100);
            const limit = Math.min(args.first ?? 20, 100);
            const where: string[] = [];
            const params: unknown[] = [];

            if (args.filter?.query) {
                where.push("(name LIKE ? OR effect LIKE ? OR category LIKE ?)");
                const q = `%${args.filter.query}%`;
                params.push(q, q, q);
            }

            let orderBy = "id";
            let direction: "ASC" | "DESC" = "ASC";
            if (args.filter?.sort === "NAME_ASC") orderBy = "name";
            if (args.filter?.sort === "CREATE_DATE_DESC") direction = "DESC";

            if (args.after != null) {
                where.push(direction === "DESC" ? "id < ?" : "id > ?");
                params.push(Number(args.after));
            }

            const sql = `SELECT * FROM spells ${where.length ? `WHERE ${where.join(" AND ")}` : ""} ORDER BY ${orderBy} ${direction} LIMIT ?`;
            params.push(limit + 1);

            const rows = db.prepare(sql).all(...params) as Spell[];
            const hasNextPage = rows.length > limit;
            const page = rows.slice(0, limit);
            const edges = page.map(spell => ({ cursor: String(spell.id), node: spell }));

            const totalCountRow = db.prepare("SELECT COUNT(*) as c FROM spells").get() as { c: number };

            return {
                edges,
                totalCount: totalCountRow.c,
                pageInfo: {
                    hasNextPage,
                    hasPreviousPage: args.after != null,
                    startCursor: edges[0]?.cursor ?? null,
                    endCursor: edges[edges.length - 1]?.cursor ?? null,
                },
            };
        },
        hogwartsTime: () => ({ id: "1", time: new Date().toISOString() }),
    },

    Mutation: {
        createSpell: async (_: unknown, { input }: { input: Partial<Spell> & { name: string; category: string; effect: string } }) => {
            await delay(300);
            const stmt = db.prepare(
                "INSERT INTO spells (name, category, creator, effect, light, imageUrl, wikiUrl) VALUES (?, ?, ?, ?, ?, ?, ?)"
            );
            const res = stmt.run(
                input.name, input.category, input.creator ?? null, input.effect,
                input.light ?? null, input.imageUrl ?? null, input.wikiUrl ?? null,
            );
            const spell = db.prepare("SELECT * FROM spells WHERE id = ?").get(res.lastInsertRowid);
            return { spell };
        },
        updateSpell: async (_: unknown, { input }: { input: Spell & { id: string } }) => {
            await delay(200);
            const { id, ...fields } = input;
            const keys = Object.keys(fields).filter(k => (fields as any)[k] !== undefined);
            if (keys.length === 0) {
                return { spell: db.prepare("SELECT * FROM spells WHERE id = ?").get(id) };
            }
            const sql = `UPDATE spells SET ${keys.map(k => `${k} = ?`).join(", ")} WHERE id = ?`;
            db.prepare(sql).run(...keys.map(k => (fields as any)[k]), id);
            return { spell: db.prepare("SELECT * FROM spells WHERE id = ?").get(id) };
        },
        deleteSpell: async (_: unknown, { input }: { input: { id: string } }) => {
            await delay(150);
            const res = db.prepare("DELETE FROM spells WHERE id = ?").run(input.id);
            return res.changes > 0;
        },
    },

    Subscription: {
        hogwartsTimeUpdated: {
            subscribe: () => pubSub.subscribe("hogwartsTimeUpdated"),
            resolve: (payload: { id: string; time: string }) => payload,
        },
    },
};

const schema = makeExecutableSchema({ typeDefs, resolvers });

const yoga = createYoga({
    schema,
    graphiql: true,
    cors: { origin: "*" },
});

const httpServer = createServer(yoga);
const wsServer = new WebSocketServer({ server: httpServer, path: yoga.graphqlEndpoint });

useServer({ schema, execute: yoga.execute, subscribe: yoga.subscribe }, wsServer);

httpServer.listen(port, () => {
    console.log(`cachebay-demo-server ready on http://localhost:${port}${yoga.graphqlEndpoint}`);
    console.log(`subscriptions:                 ws://localhost:${port}${yoga.graphqlEndpoint}`);
});
