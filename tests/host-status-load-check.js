// Issue #213: the dashboard now loads per-host documents
// (docs/host-status/<HOST>.json) via a small manifest, and merges the legacy
// fleet-wide docs/index.json underneath them so hosts that have not yet
// updated their checkout of run.sh keep showing.
//
// This checker executes the real docs/host-status.js against a stub fetch and
// asserts on the data it returns — the merge precedence, the migration
// fallbacks, and that a hostile manifest entry is never fetched.
//
// Usage: deno run --allow-read=<docs dir> host-status-load-check.js <docs-dir>
// Prints TEST_RESULT:<name>:<PASS|FAIL>:<detail> lines for the shell harness.

const docsDir = Deno.args[0];
if (!docsDir) {
    console.error("usage: host-status-load-check.js <docs-dir>");
    Deno.exit(2);
}

function report(name, ok, detail) {
    console.log(`TEST_RESULT:${name}:${ok ? "PASS" : "FAIL"}:${detail}`);
}

// Load the real browser script into an isolated scope. The file attaches its
// API to `self`, so a parameter of that name captures it without touching the
// test's own globals.
const source = await Deno.readTextFile(`${docsDir}/host-status.js`);
const scope = {};
new Function("self", source)(scope);
const api = scope.GRQHostStatus;

if (!api || typeof api.loadHostStatus !== "function") {
    report("module-api", false, "docs/host-status.js did not export loadHostStatus on self.GRQHostStatus");
    Deno.exit(1);
}

// Build a stub fetch over a { path: body } map. `null` means 404.
function stubFetch(files) {
    const requested = [];
    const fetchFn = (url) => {
        requested.push(url);
        const path = String(url).split("?")[0];
        const body = Object.prototype.hasOwnProperty.call(files, path) ? files[path] : null;
        if (body === null || body === undefined) {
            return Promise.resolve({
                ok: false,
                status: 404,
                json: () => Promise.reject(new Error("not found")),
                headers: { get: () => null },
            });
        }
        return Promise.resolve({
            ok: true,
            status: 200,
            json: () => Promise.resolve(typeof body === "string" ? JSON.parse(body) : body),
            headers: { get: () => null },
        });
    };
    return { fetchFn, requested };
}

const legacyIndex = {
    "GRQ-3": { heart_beat_ts: 100, location: "Newport Office", version: "1.1.28" },
    "GRQ-7": { heart_beat_ts: 200, location: "Home", version: "1.1.28" },
};

// --- migrated fleet: manifest + per-host documents, legacy still present ----
{
    const { fetchFn, requested } = stubFetch({
        "./host-status/index.json": { hosts: ["GRQ-3", "Mac-Ultra-M2"] },
        "./host-status/GRQ-3.json": { host: "GRQ-3", heart_beat_ts: 999, location: "Newport Office" },
        "./host-status/Mac-Ultra-M2.json": { host: "Mac-Ultra-M2", heart_beat_ts: 888 },
        "./index.json": legacyIndex,
    });
    const result = await api.loadHostStatus(fetchFn, 1234);
    const hosts = Object.keys(result.data).sort();

    report(
        "merge-both-sources",
        hosts.join(",") === "GRQ-3,GRQ-7,Mac-Ultra-M2",
        `hosts=${hosts.join(",")}`,
    );
    report(
        "per-host-wins",
        result.data["GRQ-3"].heart_beat_ts === 999,
        `GRQ-3 heart_beat_ts=${result.data["GRQ-3"].heart_beat_ts} (expected the per-host document's 999)`,
    );
    report(
        "legacy-only-host-kept",
        result.data["GRQ-7"] && result.data["GRQ-7"].heart_beat_ts === 200,
        "a host that has not migrated yet is still shown",
    );
    report(
        "no-errors-on-healthy-load",
        result.errors.length === 0,
        `errors=${JSON.stringify(result.errors)}`,
    );
    report(
        "cache-busted",
        requested.every((url) => String(url).includes("t=1234")),
        `requested=${requested.join(" ")}`,
    );
}

// --- pre-migration fleet: no manifest yet, legacy index only ---------------
{
    const { fetchFn } = stubFetch({ "./index.json": legacyIndex });
    const result = await api.loadHostStatus(fetchFn, 1);
    const hosts = Object.keys(result.data).sort();
    report(
        "legacy-only-fallback",
        hosts.join(",") === "GRQ-3,GRQ-7",
        `hosts=${hosts.join(",")}`,
    );
    report(
        "legacy-only-is-not-an-error",
        result.errors.length === 0 && result.sources.manifest === false,
        `errors=${JSON.stringify(result.errors)} manifest=${result.sources.manifest}`,
    );
}

// --- post-migration fleet: manifest only, legacy index deleted -------------
{
    const { fetchFn } = stubFetch({
        "./host-status/index.json": { hosts: ["GRQ-3"] },
        "./host-status/GRQ-3.json": { host: "GRQ-3", heart_beat_ts: 999 },
    });
    const result = await api.loadHostStatus(fetchFn, 1);
    report(
        "per-host-only",
        Object.keys(result.data).join(",") === "GRQ-3" && result.data["GRQ-3"].heart_beat_ts === 999,
        `hosts=${Object.keys(result.data).join(",")}`,
    );
}

// --- no data at all must fail loud, not render an empty fleet --------------
{
    const { fetchFn } = stubFetch({});
    let threw = false;
    let message = "";
    try {
        await api.loadHostStatus(fetchFn, 1);
    } catch (error) {
        threw = true;
        message = error.message;
    }
    report("no-data-throws", threw, `message=${message}`);
}

// --- a per-host document that 404s is surfaced, not silently dropped -------
{
    const { fetchFn } = stubFetch({
        "./host-status/index.json": { hosts: ["GRQ-3", "GRQ-9"] },
        "./host-status/GRQ-3.json": { host: "GRQ-3", heart_beat_ts: 999 },
        "./index.json": legacyIndex,
    });
    const result = await api.loadHostStatus(fetchFn, 1);
    report(
        "missing-host-document-reported",
        result.errors.some((e) => e.includes("GRQ-9")),
        `errors=${JSON.stringify(result.errors)}`,
    );
    report(
        "missing-host-document-does-not-blank-fleet",
        result.data["GRQ-3"].heart_beat_ts === 999 && Boolean(result.data["GRQ-7"]),
        "the hosts that did load are still returned",
    );
}

// --- a hostile manifest entry is never fetched -----------------------------
{
    const { fetchFn, requested } = stubFetch({
        "./host-status/index.json": { hosts: ["../../../etc/passwd", "GRQ 3; rm -rf", "GRQ-3"] },
        "./host-status/GRQ-3.json": { host: "GRQ-3", heart_beat_ts: 999 },
        "./index.json": legacyIndex,
    });
    const result = await api.loadHostStatus(fetchFn, 1);
    const traversed = requested.some((url) => String(url).includes("passwd") || String(url).includes(".."));
    report("manifest-entry-validated", !traversed, `requested=${requested.join(" ")}`);
    report(
        "rejected-entry-reported",
        result.errors.length >= 1,
        `errors=${JSON.stringify(result.errors)}`,
    );
    report(
        "valid-entry-still-loaded",
        result.data["GRQ-3"].heart_beat_ts === 999,
        "the well-formed entry alongside the hostile ones still loads",
    );
}

// --- multi-user host mid-migration: neither writer's heartbeats are lost ---
{
    // sloth still runs the old run.sh and writes only index.json; rocket has
    // migrated and writes the per-host document, seeded before sloth's latest
    // heartbeat.
    const { fetchFn } = stubFetch({
        "./host-status/index.json": { hosts: ["GRQ-21"] },
        "./host-status/GRQ-21.json": {
            host: "GRQ-21",
            heart_beat_ts: 500,
            user_count: 2,
            worst_user_heart_beat_ts: 100,
            best_user_heart_beat_ts: 500,
            exception_count: 0,
            exception_summary: "No errors found",
            users: {
                rocket: { heart_beat_ts: 500, exception_count: 0 },
                sloth: { heart_beat_ts: 100, exception_count: 0 },
            },
        },
        "./index.json": {
            "GRQ-21": {
                heart_beat_ts: 900,
                users: {
                    rocket: { heart_beat_ts: 100, exception_count: 0 },
                    sloth: { heart_beat_ts: 900, exception_count: 2, exception_summary: "2 errors found" },
                    elephant: { heart_beat_ts: 700, exception_count: 0 },
                },
            },
        },
    });
    const result = await api.loadHostStatus(fetchFn, 1);
    const host = result.data["GRQ-21"];

    report(
        "legacy-user-heartbeat-kept",
        host.users.sloth.heart_beat_ts === 900,
        `sloth heart_beat_ts=${host.users.sloth.heart_beat_ts} (expected the newer legacy 900)`,
    );
    report(
        "migrated-user-heartbeat-kept",
        host.users.rocket.heart_beat_ts === 500,
        `rocket heart_beat_ts=${host.users.rocket.heart_beat_ts} (expected the newer per-host 500)`,
    );
    report(
        "legacy-only-user-not-dropped",
        Boolean(host.users.elephant),
        `users=${Object.keys(host.users).join(",")}`,
    );
    report(
        "aggregates-recomputed",
        host.user_count === 3 && host.worst_user_heart_beat_ts === 500 &&
            host.best_user_heart_beat_ts === 900 && host.heart_beat_ts === 900,
        `user_count=${host.user_count} worst=${host.worst_user_heart_beat_ts} best=${host.best_user_heart_beat_ts} host=${host.heart_beat_ts}`,
    );
    report(
        "exception-rollup-recomputed",
        host.exception_count === 2 && host.exception_summary.includes("sloth"),
        `exception_count=${host.exception_count} summary=${host.exception_summary}`,
    );
}

// --- a broken manifest or legacy file is reported, never swallowed ---------
{
    const failing = (status) => ({
        ok: false,
        status,
        json: () => Promise.reject(new Error("not json")),
        headers: { get: () => null },
    });
    const fetchFn = (url) => {
        const path = String(url).split("?")[0];
        if (path === "./host-status/index.json") return Promise.resolve(failing(500));
        if (path === "./index.json") {
            return Promise.resolve({
                ok: true,
                status: 200,
                json: () => Promise.resolve(legacyIndex),
                headers: { get: () => null },
            });
        }
        return Promise.resolve(failing(404));
    };
    const result = await api.loadHostStatus(fetchFn, 1);
    report(
        "manifest-server-error-reported",
        result.errors.some((e) => e.includes("manifest") && e.includes("500")),
        `errors=${JSON.stringify(result.errors)}`,
    );
}

{
    const { fetchFn } = stubFetch({
        "./host-status/index.json": { notHosts: [] },
        "./index.json": legacyIndex,
    });
    const result = await api.loadHostStatus(fetchFn, 1);
    report(
        "malformed-manifest-reported",
        result.errors.some((e) => e.includes("Malformed")),
        `errors=${JSON.stringify(result.errors)}`,
    );
}

{
    // Per-host documents load, but the legacy file is broken: the hosts that
    // have not migrated are missing and that must be said out loud.
    const fetchFn = (url) => {
        const path = String(url).split("?")[0];
        const bodies = {
            "./host-status/index.json": { hosts: ["GRQ-3"] },
            "./host-status/GRQ-3.json": { host: "GRQ-3", heart_beat_ts: 999 },
        };
        if (Object.prototype.hasOwnProperty.call(bodies, path)) {
            return Promise.resolve({
                ok: true,
                status: 200,
                json: () => Promise.resolve(bodies[path]),
                headers: { get: () => null },
            });
        }
        return Promise.resolve({
            ok: false,
            status: 503,
            json: () => Promise.reject(new Error("unavailable")),
            headers: { get: () => null },
        });
    };
    const result = await api.loadHostStatus(fetchFn, 1);
    report(
        "broken-legacy-reported",
        result.errors.some((e) => e.includes("./index.json") && e.includes("503")),
        `errors=${JSON.stringify(result.errors)}`,
    );
}

// --- a hostile host name must not reach Object.prototype ------------------
{
    const { fetchFn } = stubFetch({
        "./host-status/index.json": { hosts: ["GRQ-3"] },
        "./host-status/GRQ-3.json": { host: "__proto__", polluted: true },
        "./index.json": legacyIndex,
    });
    await api.loadHostStatus(fetchFn, 1);
    report(
        "no-prototype-pollution",
        ({}).polluted === undefined,
        `Object.prototype.polluted=${({}).polluted}`,
    );
}

// --- the document's own host field wins over the manifest filename ---------
{
    const { fetchFn } = stubFetch({
        "./host-status/index.json": { hosts: ["Tinas-MacBook-Air"] },
        "./host-status/Tinas-MacBook-Air.json": { host: "Tinas MacBook Air", heart_beat_ts: 5 },
    });
    const result = await api.loadHostStatus(fetchFn, 1);
    report(
        "document-host-field-used",
        Boolean(result.data["Tinas MacBook Air"]),
        `hosts=${Object.keys(result.data).join(",")}`,
    );
}
