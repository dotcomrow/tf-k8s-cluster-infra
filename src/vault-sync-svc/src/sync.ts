import express, { Request, Response } from 'express';
import bodyParser from 'body-parser';
import { SecretManagerServiceClient } from '@google-cloud/secret-manager';
import fetch, { RequestInit, Response as FetchResponse } from 'node-fetch';

const app = express();
app.use(bodyParser.json());
const client = new SecretManagerServiceClient();

// ---------- Config ----------
const ADDRS = (process.env.VAULT_ADDRS || process.env.VAULT_ADDR || '')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean);

if (ADDRS.length === 0) {
  throw new Error('Set VAULT_ADDRS (comma-separated) or VAULT_ADDR.');
}

const CONNECT_TIMEOUT_MS = parseInt(process.env.VAULT_CONNECT_TIMEOUT_MS || '300', 10);
const READ_TIMEOUT_MS    = parseInt(process.env.VAULT_READ_TIMEOUT_MS    || '2000', 10);
const WAIT_FOR_TUNNEL_MS = parseInt(process.env.VAULT_WAIT_FOR_TUNNEL_MS || '4000', 10);
const ENFORCE_TELEPORT   = (process.env.VAULT_ENFORCE_TELEPORT || 'false').toLowerCase() === 'true';

const TUNNEL_BASE = 'http://127.0.0.1:8200';
const RETRY_STATUSES = new Set([502, 503, 504]);

function joinUrl(base: string, path: string) {
  const b = base.endsWith('/') ? base.slice(0, -1) : base;
  const p = path.startsWith('/') ? path : `/${path}`;
  return `${b}${p}`;
}

async function fetchWithTimeout(url: string, init?: RequestInit): Promise<FetchResponse> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), CONNECT_TIMEOUT_MS + READ_TIMEOUT_MS);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

// ---------- Wait for Teleport tunnel on cold start ----------
let tunnelReadyOnce = false;

async function waitForTunnelReady(): Promise<boolean> {
  if (tunnelReadyOnce) return true;
  const deadline = Date.now() + WAIT_FOR_TUNNEL_MS;
  while (Date.now() < deadline) {
    try {
      const r = await fetchWithTimeout(joinUrl(TUNNEL_BASE, '/v1/sys/health'), { method: 'GET' });
      if (r.ok || r.status === 429 || r.status === 503) { // Vault may return 429/503 when sealed/standby, but tunnel works
        tunnelReadyOnce = true;
        return true;
      }
    } catch (_) {
      // ignore and retry quickly
    }
    await new Promise(res => setTimeout(res, 100));
  }
  return false;
}

// ---------- Vault request helper (tunnel-first, with optional enforcement) ----------
async function vaultRequest(path: string, init?: RequestInit): Promise<{ res: FetchResponse; base: string }> {
  // Try to bring up the tunnel quickly on cold starts
  const tunnelUp = await waitForTunnelReady();

  const candidates = ENFORCE_TELEPORT
    ? [TUNNEL_BASE]
    : (tunnelUp ? [TUNNEL_BASE, ...ADDRS.filter(a => a !== TUNNEL_BASE)] : ADDRS);

  let lastErr: any;
  for (const base of candidates) {
    const url = joinUrl(base, path);
    try {
      const res = await fetchWithTimeout(url, init);
      if (res.ok || !RETRY_STATUSES.has(res.status)) {
        return { res, base };
      }
      lastErr = new Error(`HTTP ${res.status} from ${url}`);
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr || new Error('All VAULT endpoints failed');
}

async function vaultJson(path: string, init?: RequestInit) {
  const { res, base } = await vaultRequest(path, init);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Vault request failed (${res.status}) via ${base}: ${text}`);
  }
  const ct = res.headers.get('content-type') || '';
  return ct.includes('json') ? res.json() : res.text();
}

// ---------- Token (AppRole or static) ----------
let cachedToken: { token: string; expiresAt: number } | null = null;

async function getVaultToken(): Promise<string> {
  if (process.env.VAULT_TOKEN) return process.env.VAULT_TOKEN;
  const now = Date.now();
  if (cachedToken && now < cachedToken.expiresAt) return cachedToken.token;

  const roleId = process.env.VAULT_ROLE_ID;
  const secretId = process.env.VAULT_SECRET_ID;
  if (!roleId || !secretId) throw new Error('Missing VAULT_ROLE_ID or VAULT_SECRET_ID');

  const json = await vaultJson('/v1/auth/approle/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ role_id: roleId, secret_id: secretId }),
  });

  const token = json?.auth?.client_token as string | undefined;
  if (!token) throw new Error('Vault AppRole login failed');
  cachedToken = { token, expiresAt: now + 5 * 60_000 };
  return token;
}

// ---------- KV helpers ----------
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

// ---------- Handlers (unchanged behavior) ----------
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
        const [accessResponse] = await client.accessSecretVersion({ name: secretPath.includes('/versions/') ? secretPath : `${secretPath}/versions/latest` });
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

app.post('/sync-all', async (req: Request, res: Response) => {
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

const PORT = parseInt(process.env.PORT || '8080', 10);
app.listen(PORT, () => console.log(`Sync service listening on port ${PORT}`));
