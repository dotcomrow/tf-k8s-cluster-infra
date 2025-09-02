import express, { Request, Response } from 'express';
import bodyParser from 'body-parser';
import { SecretManagerServiceClient } from '@google-cloud/secret-manager';
import fetch, { RequestInit, Response as FetchResponse } from 'node-fetch';

const app = express();
app.use(bodyParser.json());
const client = new SecretManagerServiceClient();

/* ================================
   Config
================================== */

// VAULT_ADDRS should contain exactly two addresses in any order:
//   - External (APISIX): e.g., https://vault.app.suncoast.systems
//   - Local Teleport tunnel: http://127.0.0.1:8200
const ADDRS = (process.env.VAULT_ADDRS || process.env.VAULT_ADDR || '')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean);

if (ADDRS.length === 0) {
  throw new Error('Set VAULT_ADDRS (comma-separated) or VAULT_ADDR.');
}

const CONNECT_TIMEOUT_MS = parseInt(process.env.VAULT_CONNECT_TIMEOUT_MS || '300', 10);
const READ_TIMEOUT_MS    = parseInt(process.env.VAULT_READ_TIMEOUT_MS    || '2000', 10);

// Resolver tuning
const DEBUG_VAULT_RESOLVER = (process.env.DEBUG_VAULT_RESOLVER || 'false').toLowerCase() === 'true';
const ACTIVE_BASE_TTL_MS   = parseInt(process.env.VAULT_ACTIVE_BASE_TTL_MS || '60000', 10); // re-check every 60s by default
const PASSIVE_RECHECK_MS   = parseInt(process.env.VAULT_PASSIVE_RECHECK_MS || '30000', 10); // fire-and-forget health check

// Treat these as "reachable" health statuses even if Vault is sealed/standby/etc.
const HEALTH_OK_CODES = new Set([200, 204, 429, 472, 473, 501, 503]);
// Retryable infra errors (we'll flip on these)
const RETRY_STATUSES = new Set([502, 503, 504]);
// Flip also on auth churn during rebuilds
const FLIP_TRIGGER_STATUSES = new Set([401, 403]);

const TUNNEL_BASE = 'http://127.0.0.1:8200';

/* ================================
   Logger
================================== */
function dbg(...args: any[]) { if (DEBUG_VAULT_RESOLVER) console.log('[resolver]', ...args); }

/* ================================
   HTTP helper (with timeout)
================================== */
async function fetchWithTimeout(url: string, init?: RequestInit): Promise<FetchResponse> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), CONNECT_TIMEOUT_MS + READ_TIMEOUT_MS);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

function joinUrl(base: string, path: string) {
  const b = base.endsWith('/') ? base.slice(0, -1) : base;
  const p = path.startsWith('/') ? path : `/${path}`;
  return `${b}${p}`;
}

/* ================================
   Active endpoint auto-detection
================================== */
let activeBase: string | null = null;
let activeBaseExpiresAt = 0;

async function resolveActiveBase(): Promise<string> {
  const now = Date.now();
  if (activeBase && now < activeBaseExpiresAt) {
    dbg('using cached activeBase:', activeBase);
    return activeBase;
  }

  // Expect one external + one tunnel; tolerate any order
  const apisix = ADDRS.find(a => a !== TUNNEL_BASE);
  const tunnel = TUNNEL_BASE;
  const candidates = [apisix, tunnel].filter(Boolean) as string[];

  dbg('detecting among:', candidates);

  // Race both; pick first that answers with a health-OK status
  const probes = candidates.map(base => probe(base));
  try {
    const winner = await Promise.any(probes);
    return setActive(winner);
  } catch {
    // Both failed fast; check sequentially to build an error summary
    const errs: string[] = [];
    for (const base of candidates) {
      try {
        const ok = await isReachable(base);
        if (ok) return setActive(base);
        errs.push(`${base}: health not OK`);
      } catch (e: any) {
        errs.push(`${base}: ${String(e?.message || e)}`);
      }
    }
    throw new Error(`No Vault endpoints reachable. Details: ${errs.join(' | ')}`);
  }

  function setActive(base: string) {
    activeBase = base;
    activeBaseExpiresAt = Date.now() + ACTIVE_BASE_TTL_MS;
    dbg('detected activeBase:', base);
    return base;
  }
}

async function probe(base: string): Promise<string> {
  const r = await fetchWithTimeout(joinUrl(base, '/v1/sys/health'), { method: 'GET' });
  if (HEALTH_OK_CODES.has(r.status)) return base;
  throw new Error(`health HTTP ${r.status}`);
}

async function isReachable(base: string): Promise<boolean> {
  try {
    const r = await fetchWithTimeout(joinUrl(base, '/v1/sys/health'), { method: 'GET' });
    dbg('health', base, r.status);
    return HEALTH_OK_CODES.has(r.status);
  } catch (e) {
    dbg('health error', base, String((e as Error).message));
    return false;
  }
}

// Passive background recheck—cheap, lets us flip even between calls
setInterval(async () => {
  try {
    await resolveActiveBase();
  } catch (e) {
    dbg('passive recheck failed:', String((e as Error).message));
  }
}, PASSIVE_RECHECK_MS).unref?.();

/* ================================
   Vault request helper (flip-aware)
================================== */
async function vaultRequest(path: string, init?: RequestInit): Promise<{ res: FetchResponse; base: string }> {
  let base = await resolveActiveBase();
  let url = joinUrl(base, path);

  try {
    dbg('→ using', url);
    const res = await fetchWithTimeout(url, init);

    // If infra/auth looks flaky (rebuild/flip), invalidate and retry once
    if (!res.ok && (RETRY_STATUSES.has(res.status) || FLIP_TRIGGER_STATUSES.has(res.status))) {
      dbg('flip-trigger HTTP', res.status, '— invalidating activeBase and re-detecting');
      activeBase = null; activeBaseExpiresAt = 0;
      base = await resolveActiveBase();
      url = joinUrl(base, path);
      const res2 = await fetchWithTimeout(url, init);
      return { res: res2, base };
    }

    return { res, base };
  } catch (e) {
    // Network error: also flip & retry once
    dbg('network error — invalidating activeBase and re-detecting:', String((e as Error).message));
    activeBase = null; activeBaseExpiresAt = 0;
    base = await resolveActiveBase();
    url = joinUrl(base, path);
    const res = await fetchWithTimeout(url, init);
    return { res, base };
  }
}

/* ================================
   Auth: AppRole login
================================== */
type VaultAppRoleLoginResp = {
  auth?: {
    client_token?: string;
    lease_duration?: number;
    renewable?: boolean;
  };
};

// Cache for short-lived Vault token (in-memory, per instance)
type CachedToken = { token: string; expiresAt: number };
let cachedToken: CachedToken | null = null;

async function vaultJson<T>(path: string, init?: RequestInit): Promise<T> {
  const { res, base } = await vaultRequest(path, init);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Vault request failed (${res.status}) via ${base}: ${text}`);
  }
  if (res.status === 204) return {} as T; // no content
  const ct = res.headers.get('content-type') || '';
  if (!ct.includes('json')) {
    const text = await res.text();
    throw new Error(`Expected JSON via ${base}, got "${ct}": ${text.slice(0, 200)}`);
  }
  return res.json() as Promise<T>;
}

async function vaultText(path: string, init?: RequestInit): Promise<string> {
  const { res, base } = await vaultRequest(path, init);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Vault request failed (${res.status}) via ${base}: ${text}`);
  }
  return res.text();
}

async function getVaultToken(): Promise<string> {
  if (process.env.VAULT_TOKEN) return process.env.VAULT_TOKEN;

  const now = Date.now();
  if (cachedToken && now < cachedToken.expiresAt) return cachedToken.token;

  const roleId = process.env.VAULT_ROLE_ID;
  const secretId = process.env.VAULT_SECRET_ID;
  if (!roleId || !secretId) {
    throw new Error('Missing VAULT_ROLE_ID or VAULT_SECRET_ID');
  }

  const json = await vaultJson<VaultAppRoleLoginResp>('/v1/auth/approle/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ role_id: roleId, secret_id: secretId }),
  });

  const token = json?.auth?.client_token;
  if (!token) throw new Error('Vault AppRole login failed');

  // Simple TTL (short) to reduce logins while still flipping quickly if needed
  cachedToken = { token, expiresAt: now + 5 * 60_000 };
  return token;
}

/* ================================
   KV helpers
================================== */
async function writeToVault(dataPath: string, value: string): Promise<void> {
  const token = await getVaultToken();
  await vaultJson(`/v1/${dataPath}`, {
    method: 'POST',
    headers: { 'X-Vault-Token': token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ data: { value } }),
  });
  console.log('✅ Secret synced to Vault.');
}

async function deleteFromVault(metadataPath: string): Promise<void> {
  const token = await getVaultToken();
  await vaultJson(`/v1/${metadataPath}`, {
    method: 'DELETE',
    headers: { 'X-Vault-Token': token },
  });
  console.log('🗑️ Secret deleted from Vault.');
}

function extractSecretName(versionPath: string): string {
  const parts = versionPath.split('/');
  return parts[parts.indexOf('secrets') + 1];
}

/* ================================
   Routes
================================== */

// Event handler (Secret Manager AuditLog → push → this endpoint)
app.post('/', async (req: Request, res: Response) => {
  try {
    const event = req.body;
    const methodName = event?.protoPayload?.methodName;
    let secretPath = event?.protoPayload?.resourceName;
    if (!secretPath) throw new Error('Missing secret path in event payload');

    if (!secretPath.includes('/versions/') && methodName !== 'google.cloud.secretmanager.v1.SecretManagerService.DeleteSecret') {
      secretPath = `${secretPath}/versions/latest`;
    }

    const secretName = extractSecretName(secretPath);
    const vaultDataPath = `secret/data/${secretName}`;
    const vaultMetadataPath = `secret/metadata/${secretName}`;

    console.log(`🔔 Received Secret Manager event: ${methodName}`);

    switch (methodName) {
      case 'google.cloud.secretmanager.v1.SecretManagerService.CreateSecret':
        await writeToVault(vaultDataPath, '__PLACEHOLDER__');
        break;

      case 'google.cloud.secretmanager.v1.SecretManagerService.AddSecretVersion':
      case 'google.cloud.secretmanager.v1.SecretManagerService.UpdateSecret': {
        const [accessResponse] = await client.accessSecretVersion({
          name: secretPath.includes('/versions/') ? secretPath : `${secretPath}/versions/latest`,
        });
        const payload = accessResponse.payload?.data?.toString();
        if (!payload) throw new Error('Empty secret payload');
        await writeToVault(vaultDataPath, payload);
        break;
      }

      case 'google.cloud.secretmanager.v1.SecretManagerService.DeleteSecret':
        await deleteFromVault(vaultMetadataPath);
        break;

      default:
        console.log(`ℹ️ Unsupported method: ${methodName} — skipping`);
        break;
    }

    res.status(200).send('OK');
  } catch (err: any) {
    console.error('❗ Error:', err);
    res.status(500).send(err.message || 'Unknown error');
  }
});

// Manual sync-all
app.post('/sync-all', async (_req: Request, res: Response) => {
  try {
    const projectId = process.env.GCP_PROJECT_ID;
    if (!projectId) throw new Error('Missing GCP_PROJECT_ID');

    const [secrets] = await client.listSecrets({ parent: `projects/${projectId}` });

    for (const secret of secrets) {
      const name = secret.name;
      if (!name) continue;

      const latestVersion = `${name}/versions/latest`;
      const [accessResponse] = await client.accessSecretVersion({ name: latestVersion });
      const payload = accessResponse.payload?.data?.toString();
      if (!payload) continue;

      const secretName = extractSecretName(latestVersion);
      const vaultDataPath = `secret/data/${secretName}`;

      const token = await getVaultToken();
      const { res: r, base } = await vaultRequest(`/v1/${vaultDataPath}`, {
        method: 'POST',
        headers: { 'X-Vault-Token': token, 'Content-Type': 'application/json' },
        body: JSON.stringify({ data: { value: payload } }),
      });

      if (!r.ok) {
        const text = await r.text();
        throw new Error(`Failed to sync ${vaultDataPath} via ${base}: ${text}`);
      }
    }

    console.log('✅ All secrets synced to Vault.');
    res.status(200).send('All secrets synced.');
  } catch (err: any) {
    console.error('Error in sync-all:', err);
    res.status(500).send(err.message || 'Unknown error');
  }
});

// Diagnostics: see which base is reachable and what’s cached
app.get('/diag', async (_req: Request, res: Response) => {
  try {
    const apisix = ADDRS.find(a => a !== TUNNEL_BASE);
    const tunnel = TUNNEL_BASE;
    const bases = [apisix, tunnel].filter(Boolean) as string[];

    const out: Record<string, any> = {};
    for (const b of bases) {
      try {
        const r = await fetchWithTimeout(joinUrl(b, '/v1/sys/health'), { method: 'GET' });
        out[b] = { reachable: HEALTH_OK_CODES.has(r.status), status: r.status, statusText: r.statusText };
      } catch (e: any) {
        out[b] = { reachable: false, error: String(e?.message || e) };
      }
    }
    out.activeBase = activeBase;
    out.activeBaseValidForMs = Math.max(0, activeBaseExpiresAt - Date.now());
    res.json(out);
  } catch (e: any) {
    res.status(500).json({ error: String(e?.message || e) });
  }
});

/* ================================
   Boot
================================== */
const PORT = parseInt(process.env.PORT || '8080', 10);
app.listen(PORT, () => console.log(`Sync service listening on port ${PORT}`));
