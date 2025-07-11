import express, { Request, Response } from 'express';
import bodyParser from 'body-parser';
import { SecretManagerServiceClient } from '@google-cloud/secret-manager';
import fetch from 'node-fetch';

const app = express();
app.use(bodyParser.json());

const client = new SecretManagerServiceClient();

async function writeToVault(path: string, value: string): Promise<void> {
  const response = await fetch(`${process.env.VAULT_ADDR}/v1/${path}`, {
    method: 'POST',
    headers: {
      'X-Vault-Token': await getVaultToken(),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ data: { value } }),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Failed to write to Vault: ${text}`);
  }

  console.log("✅ Secret synced to Vault.");
}

async function deleteFromVault(metadataPath: string): Promise<void> {
  const response = await fetch(`${process.env.VAULT_ADDR}/v1/${metadataPath}`, {
    method: 'DELETE',
    headers: {
      'X-Vault-Token': await getVaultToken(),
    },
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Failed to delete from Vault: ${text}`);
  }

  console.log("🗑️ Secret deleted from Vault.");
}

function extractSecretName(versionPath: string): string {
  const parts = versionPath.split('/');
  return parts[parts.indexOf('secrets') + 1];
}

async function getVaultToken(): Promise<string> {
  if (process.env.VAULT_TOKEN) return process.env.VAULT_TOKEN;

  const roleId = process.env.VAULT_ROLE_ID;
  const secretId = process.env.VAULT_SECRET_ID;
  if (!roleId || !secretId) {
    throw new Error("Missing VAULT_ROLE_ID or VAULT_SECRET_ID");
  }

  const resp = await fetch(`${process.env.VAULT_ADDR}/v1/auth/approle/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ role_id: roleId, secret_id: secretId }),
  });

  const json = await resp.json() as { auth?: { client_token?: string } };
  const token = json?.auth?.client_token;
  if (!token) throw new Error("Vault AppRole login failed");

  return token;
}

app.post('/', async (req: Request, res: Response) => {
  try {
    const event = req.body;
    const methodName = event?.protoPayload?.methodName;
    let secretPath = event?.protoPayload?.resourceName;
    if (!secretPath) throw new Error("Missing secret path in event payload");

    // Normalize to secret version if needed
    if (!secretPath.includes("/versions/") && methodName !== "google.cloud.secretmanager.v1.SecretManagerService.DeleteSecret") {
      secretPath = `${secretPath}/versions/latest`;
    }

    const secretName = extractSecretName(secretPath);
    const vaultPath = `secret/data/${secretName}`;
    const vaultMetadataPath = `secret/metadata/${secretName}`;

    console.log(`🔔 Received Secret Manager event: ${methodName}`);

    switch (methodName) {
      case "google.cloud.secretmanager.v1.SecretManagerService.CreateSecret":
        console.log(`📁 Creating placeholder in Vault for new secret: ${vaultPath}`);
        await writeToVault(vaultPath, "__PLACEHOLDER__");
        break;
      case "google.cloud.secretmanager.v1.SecretManagerService.AddSecretVersion":
      case "google.cloud.secretmanager.v1.SecretManagerService.UpdateSecret":
        console.log(`📥 Fetching secret version: ${secretPath}`);
        const [accessResponse] = await client.accessSecretVersion({ name: secretPath });
        const payload = accessResponse.payload?.data?.toString();
        if (!payload) throw new Error("Empty secret payload");

        console.log(`🔐 Writing secret to Vault at: ${vaultPath}`);
        await writeToVault(vaultPath, payload);
        break;

      case "google.cloud.secretmanager.v1.SecretManagerService.DeleteSecret":
        console.log(`❌ Deleting secret from Vault at: ${vaultMetadataPath}`);
        await deleteFromVault(vaultMetadataPath);
        break;

      default:
        console.log(`ℹ️ Unsupported method: ${methodName} — skipping`);
        break;
    }

    res.status(200).send("OK");
  } catch (err: any) {
    console.error("❗ Error:", err);
    res.status(500).send(err.message || "Unknown error");
  }
});

app.post('/sync-all', async (req: Request, res: Response) => {
  try {
    const projectId = process.env.GCP_PROJECT_ID;
    if (!projectId) throw new Error("Missing GCP_PROJECT_ID");

    const [secrets] = await client.listSecrets({
      parent: `projects/${projectId}`,
    });

    for (const secret of secrets) {
      const name = secret.name;
      if (!name) continue;

      const latestVersion = `${name}/versions/latest`;
      const [accessResponse] = await client.accessSecretVersion({ name: latestVersion });
      const payload = accessResponse.payload?.data?.toString();
      if (!payload) continue;

      const secretName = extractSecretName(latestVersion);
      const vaultPath = `secret/data/${secretName}`;

      console.log(`Syncing ${vaultPath}`);
      const vaultResponse = await fetch(`${process.env.VAULT_ADDR}/v1/${vaultPath}`, {
        method: 'POST',
        headers: {
          'X-Vault-Token': await getVaultToken(),
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          data: {
            value: payload  // wrap the string inside an object
          }
        }),
      });

      if (!vaultResponse.ok) {
        const text = await vaultResponse.text();
        throw new Error(`Failed to sync ${vaultPath}: ${text}`);
      }
    }

    console.log("✅ All secrets synced to Vault.");
    res.status(200).send("All secrets synced.");
  } catch (err: any) {
    console.error("Error in sync-all:", err);
    res.status(500).send(err.message || "Unknown error");
  }
});

const PORT = parseInt(process.env.PORT || '8080', 10);
app.listen(PORT, () => {
  console.log(`Sync service listening on port ${PORT}`);
});