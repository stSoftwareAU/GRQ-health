/**
 * Repo feed freshness generator.
 *
 * Reads `config/repo_feeds.json`, fetches the most recent commit time for each
 * repository, then writes `docs/repos.json` so dashboards can surface the
 * status of upstream market feed workers.
 */

export const HOURS_WARNING = 36;
export const HOURS_ERROR = 72;

export type RepoStatus = "healthy" | "warning" | "error";

export interface RepoConfigEntry {
  name: string;
  repo: string;
}

export interface RepoHealthEntry extends RepoConfigEntry {
  last_commit_ts: number;
  status: RepoStatus;
}

interface GenerateOptions {
  configPath?: string;
  outputPath?: string;
  fetchImpl?: typeof fetch;
  nowTs?: number;
  token?: string;
  onStatus?: (entry: RepoHealthEntry) => void;
}

const DEFAULT_HEADERS = {
  Accept: "application/vnd.github+json",
  "User-Agent": "stSoftware-GRQ-health-repo-monitor",
};

export function classifyStatus(
  lastCommitTs: number,
  nowTs = Math.floor(Date.now() / 1000),
): RepoStatus {
  const hoursSince = (nowTs - lastCommitTs) / 3600;
  if (hoursSince >= HOURS_ERROR) {
    return "error";
  }
  if (hoursSince >= HOURS_WARNING) {
    return "warning";
  }
  return "healthy";
}

export function createRepoEntry(
  config: RepoConfigEntry,
  lastCommitTs: number,
  nowTs = Math.floor(Date.now() / 1000),
): RepoHealthEntry {
  return {
    ...config,
    last_commit_ts: lastCommitTs,
    status: classifyStatus(lastCommitTs, nowTs),
  };
}

async function fetchLatestCommitTs(
  repo: string,
  fetchImpl: typeof fetch,
  token?: string,
): Promise<number> {
  const url = `https://api.github.com/repos/${repo}/commits?per_page=1`;
  const headers = {
    ...DEFAULT_HEADERS,
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };
  const response = await fetchImpl(url, { headers });
  if (!response.ok) {
    const body = await response.text();
    throw new Error(
      `Failed to fetch commits for ${repo}: ${response.status} ${body}`,
    );
  }
  const data = await response.json();
  if (!Array.isArray(data) || data.length === 0) {
    throw new Error(`No commits returned for ${repo}`);
  }
  const commit = data[0]?.commit;
  const dateIso = commit?.committer?.date ?? commit?.author?.date;
  if (!dateIso) {
    throw new Error(`Missing commit date for ${repo}`);
  }
  const ts = Math.floor(new Date(dateIso).getTime() / 1000);
  if (Number.isNaN(ts)) {
    throw new Error(`Invalid commit date for ${repo}: ${dateIso}`);
  }
  return ts;
}

export async function generateRepoHealth(options: GenerateOptions = {}) {
  const configPath = options.configPath ??
    new URL("../config/repo_feeds.json", import.meta.url).pathname;
  const outputPath = options.outputPath ??
    new URL("../docs/repos.json", import.meta.url).pathname;
  const fetchImpl = options.fetchImpl ?? fetch;
  const nowTs = options.nowTs ?? Math.floor(Date.now() / 1000);
  const token = options.token ?? Deno.env.get("GITHUB_TOKEN");

  const rawConfig = await Deno.readTextFile(configPath);
  const parsedConfig = JSON.parse(rawConfig);
  if (!parsedConfig.repos || !Array.isArray(parsedConfig.repos)) {
    throw new Error("config file must contain a repos array");
  }

  const entries: RepoHealthEntry[] = [];

  for (const repoConfig of parsedConfig.repos as RepoConfigEntry[]) {
    if (!repoConfig?.repo || !repoConfig?.name) {
      throw new Error("Each repo config entry must include name and repo");
    }
    const lastCommitTs = await fetchLatestCommitTs(
      repoConfig.repo,
      fetchImpl,
      token,
    );
    const entry = createRepoEntry(repoConfig, lastCommitTs, nowTs);
    entries.push(entry);
    annotateStatus(entry);
    options.onStatus?.(entry);
  }

  const payload = {
    generated_at: nowTs,
    repos: entries,
  };
  const json = JSON.stringify(payload, null, 2);
  await Deno.writeTextFile(outputPath, `${json}\n`);
}

function annotateStatus(entry: RepoHealthEntry) {
  const iso = new Date(entry.last_commit_ts * 1000).toISOString();
  const message = `${entry.name} (${entry.repo}) last commit ${iso}`;
  if (entry.status === "error") {
    console.error(`::error title=Repo feed stale::${message}`);
  } else if (entry.status === "warning") {
    console.warn(`::warning title=Repo feed warning::${message}`);
  } else {
    console.log(`Repo feed healthy: ${message}`);
  }
}

if (import.meta.main) {
  await generateRepoHealth();
}

