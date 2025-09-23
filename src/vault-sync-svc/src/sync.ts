import express, { Request, Response } from 'express';
import bodyParser from 'body-parser';
import { SecretManagerServiceClient } from '@google-cloud/secret-manager';
import fetch, { RequestInit, Response as FetchResponse } from 'node-fetch';

const app = express();
// Accept reasonably large payloads safely
app.use(bodyParser.json({ limit: '5mb' }));

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

const CONNECT_TIMEOUT_MS = parseInt(process.env.VAULT_CONNECT_TIMEOUT_MS || '2000', 10);
const READ_TIMEOUT_MS    = parseInt(process.env.VAULT_READ_TIMEOUT_MS    || '3000', 10);

// Resolver tuning
const DEBUG_VAULT_RESOLVER = (process.env.DEBUG_VAULT_RESOLVER || 'false').toLowerCase() === 'true';
const ACTIVE_BASE_TTL_MS   = parseInt(process.env.VAULT_ACTIVE_BASE_TTL_MS || '10000', 10);
const PASSIVE_RECHECK_MS   = parseInt(process.env.VAULT_PASSIVE_RECHECK_MS || '5000', 10);

// Treat these as "reachable" health statuses even if Vault is sealed/standby/etc.
const HEALTH_OK_CODES = new Set([200, 204, 429, 472, 473, 501, 503]);
// Retryable infra errors (we'll flip on these)
const RETRY_STATUSES = new Set([502, 503, 504]);
// Flip also on auth churn during rebuilds
const FLIP_TRIGGER_STATUSES = new Set([401, 403]);

const TUNNEL_BASE = 'http://127.0.0.1:8200';

/* ================================
   Small logging helpers
================================== */
function dbg(...args: any[]) { if (DEBUG_VAULT_RESOLVER) console.log('[resolver]', ...args); }

function head(str: string, n = 500) {
  if (!str) return '';
  return str.length > n ? `${str.slice(0, n)}…(+${str.length - n} bytes)` : str;
}

function safePreview(obj: unknown, n = 500) {
  try { return head(JSON.stringify(obj), n); }
  catch { return '[unserializable]'; }
}

/* ================================
   HTTP helper (with timeout)
================================== */
async function fetchWithTimeout(url: string, init?: RequestInit): Promise<FetchResponse> {
  const controller = new AbortController();
  const totalTimeout = CONNECT_TIMEOUT_MS + READ_TIMEOUT_MS;
  const timeout = setTimeout(() => controller.abort(), totalTimeout);
  try {
    return await fetch(url, { 
      ...init, 
      signal: controller.signal
    });
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

  const apisix = ADDRS.find(a => a !== TUNNEL_BASE);
  const tunnel = TUNNEL_BASE;
  const candidates = [apisix, tunnel].filter(Boolean) as string[];

  dbg('detecting among:', candidates);

  const probes = candidates.map(base => probe(base));
  try {
    const winner = await Promise.any(probes);
    return setActive(winner);
  } catch {
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
async function vaultRequest(path: string, init?: RequestInit, maxRetries: number = 2): Promise<{ res: FetchResponse; base: string }> {
  let base = await resolveActiveBase();
  let url = joinUrl(base, path);
  let lastError: Error | null = null;

  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      dbg(`→ attempt ${attempt + 1}/${maxRetries} using`, url);
      const res = await fetchWithTimeout(url, init);

      // If infra/auth looks flaky (rebuild/flip), invalidate and retry
      if (!res.ok && (RETRY_STATUSES.has(res.status) || FLIP_TRIGGER_STATUSES.has(res.status))) {
        dbg('flip-trigger HTTP', res.status, '— invalidating activeBase and re-detecting');
        activeBase = null; activeBaseExpiresAt = 0;
        
        if (attempt < maxRetries - 1) {
          base = await resolveActiveBase();
          url = joinUrl(base, path);
          continue;
        }
      }

      return { res, base };
    } catch (e) {
      dbg(`network error on attempt ${attempt + 1}/${maxRetries} — invalidating activeBase and re-detecting:`, String((e as Error).message));
      lastError = e as Error;
      activeBase = null; activeBaseExpiresAt = 0;
      
      if (attempt < maxRetries - 1) {
        base = await resolveActiveBase();
        url = joinUrl(base, path);
        continue;
      }
    }
  }

  throw lastError || new Error('All vault request attempts failed');
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
  if (res.status === 204) return {} as T;
  const ct = res.headers.get('content-type') || '';
  if (!ct.includes('json')) {
    const text = await res.text();
    throw new Error(`Expected JSON via ${base}, got "${ct}": ${text.slice(0, 200)}`);
  }
  return res.json() as Promise<T>;
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

  // Short cache to reduce logins but flip quickly
  cachedToken = { token, expiresAt: now + 2 * 60_000 };
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
  console.log('✅ Secret synced to Vault at', dataPath);
}

async function deleteFromVault(metadataPath: string): Promise<void> {
  const token = await getVaultToken();
  await vaultJson(`/v1/${metadataPath}`, {
    method: 'DELETE',
    headers: { 'X-Vault-Token': token },
  });
  console.log('🗑️ Secret deleted from Vault at', metadataPath);
}

function extractSecretName(versionPath: string): string {
  const parts = versionPath.split('/');
  return parts[parts.indexOf('secrets') + 1];
}

/* ================================
   Event normalization
   - Accepts CloudEvent (Eventarc), Pub/Sub push, or raw AuditLog JSON
================================== */
type NormalizedEvent = {
  methodName: string | undefined;
  resourceName: string | undefined;
  rawPreview: string;
};

function decodeBase64(b64?: string | null): string {
  if (!b64) return '';
  try { return Buffer.from(b64, 'base64').toString('utf8'); }
  catch { return ''; }
}

function normalizeEvent(req: Request): NormalizedEvent {
  const ceType  = req.header('ce-type') || '';
  const ceId    = req.header('ce-id') || '';
  const ceSrc   = req.header('ce-source') || '';
  const ceSubj  = req.header('ce-subject') || '';

  // Log CloudEvent headers briefly
  if (ceType) {
    console.log('[event] ce-type=%s ce-id=%s ce-source=%s ce-subject=%s', ceType, ceId, ceSrc, ceSubj);
  } else {
    console.log('[event] no CloudEvent headers detected');
  }

  const body = req.body || {};

  // Case A: Eventarc → Pub/Sub → Cloud Run (CloudEvent with Pub/Sub message)
  // Shape: { message: { data: "<base64>", attributes?: {...}, messageId, publishTime }, subscription: "..." }
  if (body && typeof body === 'object' && body.message && typeof body.message.data === 'string') {
    const decoded = decodeBase64(body.message.data);
    console.log('[event] pubsub envelope detected; decoded len=%d', decoded.length);
    const parsed = safeParseJson(decoded);
    const methodName = parsed?.protoPayload?.methodName;
    const resourceName = parsed?.protoPayload?.resourceName;
    return { methodName, resourceName, rawPreview: head(decoded) };
  }

  // Case B: Eventarc (AuditLog) delivers CloudEvent with data field only:
  // Body can be the AuditLog entry directly or wrapped under "data".
  const maybeData = (body && (body.data || body));
  if (maybeData && typeof maybeData === 'object' && (maybeData.protoPayload || body.protoPayload)) {
    const node = (body.data?.protoPayload) ? body.data : body;
    const methodName = node?.protoPayload?.methodName;
    const resourceName = node?.protoPayload?.resourceName;
    return { methodName, resourceName, rawPreview: head(JSON.stringify(node)) };
  }

  // Case C: Your manual direct JSON (raw AuditLog entry as root)
  if (body && body.protoPayload) {
    const methodName = body.protoPayload?.methodName;
    const resourceName = body.protoPayload?.resourceName;
    return { methodName, resourceName, rawPreview: head(JSON.stringify(body)) };
  }

  // Unknown format
  return { methodName: undefined, resourceName: undefined, rawPreview: safePreview(body) };
}

function safeParseJson(s: string): any {
  try { return JSON.parse(s); } catch { return undefined; }
}

/* ================================
   Routes
================================== */

// Main event handler
app.post('/', async (req: Request, res: Response) => {
  const norm = normalizeEvent(req);
  const { methodName, resourceName } = norm;

  // Reject (but ACK) if format is unusable
  if (!methodName || !resourceName) {
    console.error('⚠️  Bad/unsupported event; will ACK to stop retries. preview=%s', norm.rawPreview);
    return res.status(204).send('ignored');  // ACK so the message is dropped
  }

  // For delete we expect the secret path without /versions; for others we’ll ensure latest
  let secretPath = resourceName;
  const isDelete = methodName === 'google.cloud.secretmanager.v1.SecretManagerService.DeleteSecret';

  if (!isDelete && !secretPath.includes('/versions/')) {
    secretPath = `${secretPath}/versions/latest`;
  }

  const secretName = extractSecretName(secretPath);
  const vaultDataPath     = `secret/data/${secretName}`;
  const vaultMetadataPath = `secret/metadata/${secretName}`;

  console.log('🔔 Event: method=%s secretPath=%s (secret=%s)', methodName, secretPath, secretName);

  try {
    switch (methodName) {
      case 'google.cloud.secretmanager.v1.SecretManagerService.CreateSecret': {
        // Seed a placeholder so the path exists in Vault
        await writeToVault(vaultDataPath, '__PLACEHOLDER__');
        break;
      }
      case 'google.cloud.secretmanager.v1.SecretManagerService.AddSecretVersion':
      case 'google.cloud.secretmanager.v1.SecretManagerService.UpdateSecret': {
        // Fetch payload from GSM
        const [accessResponse] = await client.accessSecretVersion({
          name: secretPath.includes('/versions/') ? secretPath : `${secretPath}/versions/latest`,
        });
        const payload = accessResponse.payload?.data?.toString();
        if (!payload) {
          // Permanent problem (empty secret) — log & ACK so we don’t spin
          console.error('⚠️  Empty secret payload for %s; ACKing.', secretPath);
          return res.status(204).send('empty payload');
        }
        await writeToVault(vaultDataPath, payload);
        break;
      }
      case 'google.cloud.secretmanager.v1.SecretManagerService.DeleteSecret': {
        // Permanent removal — delete Vault secret too
        await deleteFromVault(vaultMetadataPath);
        break;
      }
      default: {
        console.log('ℹ️  Unhandled method: %s — ACKing.', methodName);
        return res.status(204).send('ignored');
      }
    }

    console.log('✅ Done: %s -> %s', methodName, isDelete ? vaultMetadataPath : vaultDataPath);
    return res.status(200).send('OK');
  } catch (err: any) {
    // Transient errors (Vault/SM network, etc.) — return 500 to let Eventarc/Pub/Sub retry
    console.error('❗ Handler error (will retry):', err?.message || err, 'stack=', err?.stack);
    return res.status(500).send(err?.message || 'Unknown error');
  }
});

// Manual sync-all (unchanged except for a bit more logging)
app.post('/sync-all', async (_req: Request, res: Response) => {
  try {
    const projectId = process.env.GCP_PROJECT_ID;
    if (!projectId) throw new Error('Missing GCP_PROJECT_ID');

    console.log('[sync-all] listing secrets in project %s', projectId);
    const [secrets] = await client.listSecrets({ parent: `projects/${projectId}` });

    let count = 0;
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
      count++;
    }

    console.log('✅ [sync-all] synced %d secrets to Vault.', count);
    res.status(200).send(`Synced ${count} secrets.`);
  } catch (err: any) {
    console.error('❗ [sync-all] error:', err?.message || err, 'stack=', err?.stack);
    res.status(500).send(err?.message || 'Unknown error');
  }
});

// Diagnostics
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

// Liveness
app.get('/healthz', (_req, res) => res.status(200).send('ok'));

/* ================================
   Boot
================================== */
const PORT = parseInt(process.env.PORT || '8080', 10);
app.listen(PORT, () => console.log(`Sync service listening on port ${PORT}`));
