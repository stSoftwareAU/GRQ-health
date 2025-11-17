import { assertEquals } from "https://deno.land/std/assert/assert_equals.ts";
import { assertRejects } from "https://deno.land/std/assert/assert_rejects.ts";

import {
  classifyStatus,
  createRepoEntry,
  generateRepoHealth,
  HOURS_ERROR,
  HOURS_WARNING,
  RepoHealthEntry,
  RepoStatus,
} from "./repo_feed_health.ts";

function hoursAgoFrom(baseTs: number, hours: number): number {
  return baseTs - hours * 3600;
}

Deno.test("classifyStatus respects warning and error thresholds", () => {
  const base = 1_700_000_000;
  assertEquals(classifyStatus(hoursAgoFrom(base, 2), base), "healthy");
  assertEquals(
    classifyStatus(hoursAgoFrom(base, HOURS_WARNING), base),
    "warning",
  );
  assertEquals(
    classifyStatus(hoursAgoFrom(base, HOURS_ERROR + 1), base),
    "error",
  );
});

Deno.test("createRepoEntry maps config and timestamps into repo entries", () => {
  const now = 1_700_000_000;
  const entry = createRepoEntry(
    { name: "FX", repo: "stSoftwareAU/GRQ-FX" },
    now - 10,
    now,
  );

  assertEquals(entry.name, "FX");
  assertEquals(entry.repo, "stSoftwareAU/GRQ-FX");
  assertEquals(entry.status, "healthy");
  assertEquals(entry.last_commit_ts, now - 10);
});

Deno.test("generateRepoHealth writes docs and emits statuses", async () => {
  const tempDir = await Deno.makeTempDir();
  const configPath = `${tempDir}/repos.json`;
  const outputPath = `${tempDir}/repos-out.json`;
  const fakeNow = 1_700_000_000;

  const config = {
    repos: [
      { name: "FX", repo: "stSoftwareAU/GRQ-FX" },
      { name: "commodities", repo: "stSoftwareAU/GRQ-commodities" },
    ],
  };
  await Deno.writeTextFile(configPath, JSON.stringify(config, null, 2));

  const commitMap: Record<string, number> = {
    "stSoftwareAU/GRQ-FX": hoursAgoFrom(fakeNow, 2),
    "stSoftwareAU/GRQ-commodities": hoursAgoFrom(fakeNow, HOURS_ERROR + 2),
  };

  const fakeFetch: typeof fetch = (input) => {
    const url = new URL(input as string);
    const pathParts = url.pathname.split("/");
    const repoSlug = `${pathParts[2]}/${pathParts[3]}`;
    const ts = commitMap[repoSlug];
    if (ts === undefined) {
      return Promise.resolve(new Response("{}", { status: 404 }));
    }

    const iso = new Date(ts * 1000).toISOString();
    const body = JSON.stringify([{
      commit: { committer: { date: iso } },
    }]);
    return Promise.resolve(new Response(body, { status: 200 }));
  };

  const warnings: Array<{ repo: string; status: RepoStatus }> = [];

  await generateRepoHealth({
    configPath,
    outputPath,
    fetchImpl: fakeFetch,
    nowTs: fakeNow,
    onStatus: (entry: RepoHealthEntry) =>
      warnings.push({ repo: entry.repo, status: entry.status }),
  });

  const output = JSON.parse(await Deno.readTextFile(outputPath));
  assertEquals(output.repos.length, 2);

  const fx = output.repos.find((r: { repo: string }) => r.repo === "stSoftwareAU/GRQ-FX");
  const commodities = output.repos.find((r: { repo: string }) => r.repo === "stSoftwareAU/GRQ-commodities");

  assertEquals(fx.status, "healthy");
  assertEquals(commodities.status, "error");
  const hasError = warnings.some((w) => w.status === "error");
  assertEquals(hasError, true);
});

Deno.test("generateRepoHealth tolerates fetch failures without crashing", async () => {
  const tempDir = await Deno.makeTempDir();
  const configPath = `${tempDir}/repos.json`;
  const outputPath = `${tempDir}/repos-out.json`;
  await Deno.writeTextFile(
    configPath,
    JSON.stringify({ repos: [{ name: "FX", repo: "stSoftwareAU/GRQ-FX" }] }),
  );

  const failingFetch: typeof fetch = () =>
    Promise.resolve(new Response("{}", { status: 404 }));

  await generateRepoHealth({
    configPath,
    outputPath,
    fetchImpl: failingFetch,
    nowTs: 1_700_000_000,
  });

  const output = JSON.parse(await Deno.readTextFile(outputPath));
  assertEquals(output.repos.length, 1);
  const entry = output.repos[0];
  assertEquals(entry.status, "error");
  assertEquals(typeof entry.error_message, "string");
  assertEquals(entry.error_message.includes("Failed to fetch commits"), true);
});

Deno.test("generateRepoHealth fails when config missing repos array", async () => {
  const tempDir = await Deno.makeTempDir();
  const badConfigPath = `${tempDir}/bad.json`;
  await Deno.writeTextFile(badConfigPath, JSON.stringify({}));

  await assertRejects(() =>
    generateRepoHealth({
      configPath: badConfigPath,
      outputPath: `${tempDir}/out.json`,
      fetchImpl: () => Promise.resolve(new Response("[]", { status: 200 })),
    })
  );
});

