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
  repo?: string;
  url?: string;
}

export interface RepoHealthEntry extends RepoConfigEntry {
  repo: string;
  last_commit_ts: number;
  status: RepoStatus;
  error_message?: string;
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
  config: RepoConfigEntry & { repo: string },
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
  const token = options.token ??
    Deno.env.get("REPO_FEED_TOKEN") ??
    Deno.env.get("GITHUB_TOKEN");

  const rawConfig = await Deno.readTextFile(configPath);
  const parsedConfig = JSON.parse(rawConfig);
  if (!parsedConfig.repos || !Array.isArray(parsedConfig.repos)) {
    throw new Error("config file must contain a repos array");
  }

  const entries: RepoHealthEntry[] = [];

  for (const repoConfig of parsedConfig.repos as RepoConfigEntry[]) {
    if (!repoConfig?.name) {
      throw new Error("Each repo config entry must include a name");
    }
    const repoSlug = deriveRepoSlug(repoConfig);
    let entry: RepoHealthEntry;
    try {
      const lastCommitTs = await fetchLatestCommitTs(
        repoSlug,
        fetchImpl,
        token,
      );
      entry = createRepoEntry({ ...repoConfig, repo: repoSlug }, lastCommitTs, nowTs);
    } catch (error) {
      const fallbackTs = nowTs - (HOURS_ERROR * 3600 + 60);
      entry = {
        ...repoConfig,
        repo: repoSlug,
        last_commit_ts: fallbackTs,
        status: "error",
        error_message: error instanceof Error ? error.message : String(error),
      };
    }
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
  const iso = entry.last_commit_ts > 0
    ? new Date(entry.last_commit_ts * 1000).toISOString()
    : "Unknown";
  const details = entry.error_message
    ? `${entry.name} (${entry.repo}) last commit ${iso} – ${entry.error_message}`
    : `${entry.name} (${entry.repo}) last commit ${iso}`;
  if (entry.status === "error") {
    console.error(`::error title=Repo feed stale::${details}`);
  } else if (entry.status === "warning") {
    console.warn(`::warning title=Repo feed warning::${details}`);
  } else {
    console.log(`Repo feed healthy: ${details}`);
  }
}

export function deriveRepoSlug(config: RepoConfigEntry): string {
  if (config.repo && config.repo.trim().length > 0) {
    return sanitizeSlug(config.repo.trim());
  }
  if (config.url) {
    const slug = extractSlugFromUrl(config.url);
    if (slug) {
      return slug;
    }
  }
  throw new Error(
    `Repo config "${config.name}" must specify either repo or a valid GitHub url`,
  );
}

function sanitizeSlug(slug: string): string {
  const trimmed = slug.replace(/\.git$/i, "");
  if (trimmed.split("/").length !== 2) {
    throw new Error(`Invalid repo slug: ${slug}`);
  }
  return trimmed;
}

function extractSlugFromUrl(rawUrl: string): string | null {
  const value = rawUrl.trim();
  if (!value) {
    return null;
  }
  const httpsMatch = matchHttpsUrl(value);
  if (httpsMatch) {
    return httpsMatch;
  }
  const sshMatch = matchSshUrl(value);
  if (sshMatch) {
    return sshMatch;
  }
  if (value.includes("/")) {
    // fallback for already formatted owner/repo values possibly missing schema
    return sanitizeSlug(value);
  }
  return null;
}

function matchHttpsUrl(value: string): string | null {
  if (!value.startsWith("http://") && !value.startsWith("https://")) {
    return null;
  }
  try {
    const url = new URL(value);
    if (!url.hostname.endsWith("github.com")) {
      return null;
    }
    const pathParts = url.pathname.replace(/^\/|\/$/g, "").split("/");
    if (pathParts.length >= 2) {
      return sanitizeSlug(`${pathParts[0]}/${pathParts[1]}`);
    }
  } catch {
    return null;
  }
  return null;
}

function matchSshUrl(value: string): string | null {
  const sshPattern = /^git@[^:]+:([^/]+)\/(.+)$/;
  const match = value.match(sshPattern);
  if (!match) {
    return null;
  }
  return sanitizeSlug(`${match[1]}/${match[2]}`);
}

if (import.meta.main) {
  await generateRepoHealth();
}

