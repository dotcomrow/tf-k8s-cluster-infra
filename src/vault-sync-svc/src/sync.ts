import express, { Request, Response } from 'express';
import bodyParser from 'body-parser';
import { SecretManagerServiceClient } from '@google-cloud/secret-manager';
import fetch, { RequestInit, Response as FetchResponse } from 'node-fetch';

const app = express();
app.use(bodyParser.json());

const client = new SecretManagerServiceClient();

// ---------- Teleport-tunnel-first vault access ----------
const ADDRS = (process.env.VAULT_ADDRS || process.env.VAULT_ADDR || '')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean);
if (ADDRS.length === 0) {
  throw new Error('Set VAULT_ADDRS (comma-separated) or VAULT_ADDR.');
}

const CONNECT_TIMEOUT_MS = parseInt(process.env.VAULT_CONNECT_TIMEOUT_MS || '300', 10);
const READ_TIMEOUT_MS    = parseInt(process.env.VAULT_READ_TIMEOUT_MS    || '2000', 10);
const RETRY_STATUSES = new Set([502, 503, 504]);

function joinUrl(base: string, path: string): string {
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

/**
 * Try each VAULT address in order. On network error or 502/503/504, try the next.
 * On 2xx/4xx (other than above), return the response from that address.
 */
async function vaultRequest(path: string, init?: RequestInit): Promise<{ res: FetchResponse; base: string }> {
  let lastErr: any;
  for (const base of ADDRS) {
    const url = joinUrl(base, path);
    try {
      const res = await fetchWithTimeout(url, init);
      if (res.ok || !RETRY_STATUSES.has(res.status)) {
        return { res, base };
      }
      // Retryable status — try next address
      lastErr = new Error(`HTTP ${res.status} from ${url}`);
    } catch (e: any) {
      // Connection/timeout — try next
      lastErr = e;
    }
  }
  throw lastErr || new Error('All VAULT_ADDRS failed');
}

async function vaultJson(path: string, init?: RequestInit): Promise<any> {
  const { res, base } = await vaultRequest(path, init);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Vault request failed (${res.status}) via ${base}: ${text}`);
  }
  const ct = res.headers.get('content-type') || '';
  if (!ct.includes('json')) return res.text();
  return res.json();
}

// ---------- Vault token (AppRole or static) ----------
let cachedToken: { token: string; expiresAt: number } | null = null;

async function getVaultToken(): Promise<string> {
  if (process.env.VAULT_TOKEN) return process.env.VAULT_TOKEN;

  // Simple 5-minute client cache to reduce logins
  const now = Date.now();
  if (cachedToken && now < cachedToken.expiresAt) {
    return cachedToken.token;
  }

  const roleId = process.env.VAULT_ROLE_ID;
  const secretId = process.env.VAULT_SECRET_ID;
  if (!roleId || !secretId) {
    throw new Error('Missing VAULT_ROLE_ID or VAULT_SECRET_ID');
  }

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

// ---------- Helpers for KV v2 (paths you already use) ----------
async function writeToVault(dataPath: string, value: string): Promise<void> {
  const token = await getVaultToken();
  const body = JSON.stringify({ data: { value } });

  await vaultJson(`/v1/${dataPath}`, {
    method: 'POST',
    headers: {
      'X-Vault-Token': token,
      'Content-Type': 'application/json',
    },
    body,
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

// ---------- HTTP handlers ----------
app.post('/', async (req: Request, res: Response) => {
  try {
    const event = req.body;
    const methodName = event?.protoPayload?.methodName;
    let secretPath = event?.protoPayload?.resourceName;
    if (!secretPath) throw new Error('Missing secret path in event payload');

    // Normalize to secret version if needed
    if (!secretPath.includes('/versions/') && methodName !== 'google.cloud.secretmanager.v1.SecretManagerService.DeleteSecret') {
      secretPath = `${secretPath}/versions/latest`;
    }

    const secretName = extractSecretName(secretPath);
    const vaultDataPath = `secret/data/${secretName}`;
    const vaultMetadataPath = `secret/metadata/${secretName}`;

    console.log(`🔔 Received Secret Manager event: ${methodName}`);

    switch (methodName) {
      case 'google.cloud.secretmanager.v1.SecretManagerService.CreateSecret':
        console.log(`📁 Creating placeholder in Vault for new secret: ${vaultDataPath}`);
        await writeToVault(vaultDataPath, '__PLACEHOLDER__');
        break;

      case 'google.cloud.secretmanager.v1.SecretManagerService.AddSecretVersion':
      case 'google.cloud.secretmanager.v1.SecretManagerService.UpdateSecret': {
        console.log(`📥 Fetching secret version: ${secretPath}`);
        let versionedSecretPath = secretPath;
        if (!versionedSecretPath.includes('/versions/')) {
          versionedSecretPath += '/versions/latest';
        }

        const [accessResponse] = await client.accessSecretVersion({ name: versionedSecretPath });
        const payload = accessResponse.payload?.data?.toString();
        if (!payload) throw new Error('Empty secret payload');

        console.log(`🔐 Writing secret to Vault at: ${vaultDataPath}`);
        await writeToVault(vaultDataPath, payload);
        break;
      }

      case 'google.cloud.secretmanager.v1.SecretManagerService.DeleteSecret':
        console.log(`❌ Deleting secret from Vault at: ${vaultMetadataPath}`);
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

      console.log(`Syncing ${vaultDataPath}`);
      const token = await getVaultToken();
      const { res: r, base } = await vaultRequest(`/v1/${vaultDataPath}`, {
        method: 'POST',
        headers: {
          'X-Vault-Token': token,
          'Content-Type': 'application/json',
        },
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
app.listen(PORT, () => {
  console.log(`Sync service listening on port ${PORT}`);
});
