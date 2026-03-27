| =========================================================================
# API_KEY_VAULT.md
# Housing Radius Analyzer — API Key Vault Reference
# =========================================================================
#
# THIS FILE IS SAFE TO COMMIT — it contains no live secrets.
# It documents where keys live, how to rotate them, and how the system
# retrieves them at runtime across local MATLAB, Git, and Azure contexts.
# =========================================================================

## Overview

The system uses three external API keys and one Azure credential.  
Keys are NEVER stored in source code. They flow from one of three vaults
depending on where the code is running:

```
┌─────────────────────────────────────────────────────────────┐
│  Runtime context       │  Key source                        │
├─────────────────────────────────────────────────────────────┤
│  Local MATLAB session  │  config.json  (gitignored)         │
│  Azure Pipeline (CI)   │  Azure DevOps Variable Group       │
│  Azure Function / VM   │  Azure Key Vault (managed identity)│
│  GitHub Actions        │  GitHub Encrypted Secrets          │
└─────────────────────────────────────────────────────────────┘
```

---

## Required keys

### 1 — Census Bureau API Key

| Field        | Value |
|-------------|-------|
| Config key   | `census_api_key` |
| Env variable | `CENSUS_API_KEY` |
| Used by      | `HousingRadiusAnalyzer.m`, `fetchHousingData.m`, `fetchCensusGDP.m` |
| Endpoints    | `api.census.gov/data` (ACS, CBP, Decennial) |
| Register     | https://api.census.gov/data/key_signup.html |
| Cost         | Free — no rate limit tier, ~500 req/day unauthenticated, unlimited with key |
| Expiry       | Does not expire |
| Format       | 40-character alphanumeric string |

**Registration steps:**
1. Visit https://api.census.gov/data/key_signup.html
2. Enter your organisation name and email address
3. Key arrives by email within 60 seconds
4. Activate the key by clicking the link in the email

---

### 2 — Bureau of Economic Analysis (BEA) API Key

| Field        | Value |
|-------------|-------|
| Config key   | `bea_api_key` |
| Env variable | `BEA_API_KEY` |
| Used by      | `fetchCensusGDP.m` |
| Endpoints    | `apps.bea.gov/api/data` (CAGDP1, CAGDP2, CAINC1) |
| Register     | https://apps.bea.gov/API/signup/index.cfm |
| Cost         | Free — 100 req/min, 1,000 req/day |
| Expiry       | Does not expire (revocable via BEA portal) |
| Format       | UUID string, e.g. `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |

**Registration steps:**
1. Visit https://apps.bea.gov/API/signup/index.cfm
2. Fill in name, organisation, email, intended use
3. Key appears on-screen and is emailed immediately

---

### 3 — HUD USPS Crosswalk API Token

| Field        | Value |
|-------------|-------|
| Config key   | `hud_token` |
| Env variable | `HUD_TOKEN` |
| Used by      | `HousingRadiusAnalyzer.m` (fetchHUDData) |
| Endpoints    | `www.huduser.gov/hudapi/public` |
| Register     | https://www.huduser.gov/hudapi/public/register |
| Cost         | Free |
| Expiry       | Bearer tokens expire — **renew every 6 months** |
| Format       | JWT Bearer token (long alphanumeric string) |

**Registration steps:**
1. Visit https://www.huduser.gov/hudapi/public/register
2. Create a free account
3. Log in → navigate to "My Applications" → "Generate Token"
4. Copy the token — it is only shown once

**Renewal reminder:**
HUD tokens expire. Set a calendar reminder every 5 months.  
To renew: log in → "My Applications" → revoke old token → generate new one →  
update `config.json` locally and the `HUD_TOKEN` secret in Azure DevOps and GitHub.

---

### 4 — Azure Storage Connection String (pipeline only)

| Field        | Value |
|-------------|-------|
| Config key   | `azure.storage_account` |
| Env variable | `AZURE_STORAGE_CONN_STRING` |
| Used by      | `azure-pipelines.yml` (publish stage) |
| Purpose      | Upload CSV/JSON/XML outputs to Azure Blob Storage |
| Obtain       | Azure Portal → Storage Account → Access Keys → Connection string |
| Expiry       | Does not expire unless account is rotated |

---

## Local setup (config.json)

`config.json` is gitignored. It must be created manually from the template:

```bash
# In your repo root:
cp config.template.json config.json
```

Then open `config.json` and fill in your keys:

```json
{
  "census_api_key": "YOUR_40_CHAR_CENSUS_KEY",
  "bea_api_key":    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "hud_token":      "YOUR_HUD_JWT_TOKEN",
  ...
}
```

**Verify it is gitignored before committing:**
```bash
git check-ignore -v config.json
# Expected output: .gitignore:6:config.json    config.json
```

---

## Azure DevOps Variable Group setup

In Azure DevOps → Pipelines → Library → Variable Groups:

1. Click **+ Variable Group**
2. Name it exactly: `hra-secrets`
3. Add these variables (click the lock icon to mark as secret):
|
| Variable name | Secret? | Value |
|--------------|---------|-------|
| `CENSUS_API_KEY` | ✅ Yes | Your Census key |
| `BEA_API_KEY` | ✅ Yes | Your BEA UUID key |
| `HUD_TOKEN[]` | ✅ Yes | Your HUD JWT token |
| `AZURE_STORAGE_CONN_STRING` | ✅ Yes | Azure connection string |

4. Under **Pipeline permissions**, grant access to your pipeline.

The pipeline YAML references these via `$(CENSUS_API_KEY)` syntax and injects them into `config.json` at runtime before MATLAB runs. They are never written to disk or logged.

---

l

## GitHub Actions Secrets setup

In GitHub → Settings → Secrets and Variables → Actions:

1. Click **New repository secret** for each:

| Secret name | Value |
|-------------|-------|
| `CENSUS_API_KEY` | Your Census key |
| `BEA_API_KEY` | Your BEA UUID key |
| `HUD_TOKEN` | Your HUD JWT token |
| `AZURE_STORAGE_CONN_STRING` | Azure connection string |

Referenced in workflows as `${{ secrets.CENSUS_API_KEY }}`.

---

## Azure Key Vault (production hardening)

For production deployments, keys should be stored in Azure Key Vault rather than variable groups:

```bash
# Create Key Vault
az keyvault create \
  --name hra-keyvault \
  --resource-group hra-rg \
  --location eastus

# Store secrets
az keyvault secret set --vault-name hra-keyvault --name CENSUS-API-KEY --value "YOUR_KEY"
az keyvault secret set --vault-name hra-keyvault --name BEA-API-KEY    --value "YOUR_KEY"
az keyvault secret set --vault-name hra-keyvault --name HUD-TOKEN      --value "YOUR_TOKEN"

# Grant pipeline managed identity read access
az keyvault set-policy \
  --name hra-keyvault \
  --spn YOUR_PIPELINE_SERVICE_PRINCIPAL \
  --secret-permissions get list
```

In `azure-pipelines.yml`, add the AzureKeyVault task before the MATLAB run step:

```yaml
- task: AzureKeyVault@2
  inputs:
    azureSubscription: 'HRA-Azure-ServiceConnection'
    KeyVaultName: 'hra-keyvault'
    SecretsFilter: 'CENSUS-API-KEY,BEA-API-KEY,HUD-TOKEN'
    RunAsPreJob: true
```

---

## Key rotation checklist

Run this checklist when rotating any key:

- [ ] Generate new key at the provider portal
- [ ] Update `config.json` on your local machine
- [ ] Update the Azure DevOps Variable Group secret
- [ ] Update the GitHub Actions secret
- [ ] If using Azure Key Vault: `az keyvault secret set ...`
- [ ] Trigger a test pipeline run to confirm the new key works
- [ ] Revoke the old key at the provider portal
- [ ] Update the `Expiry` field in this document

---

## Emergency: suspected key compromise

If a key is leaked (e.g. accidentally committed to a public repo):

1. **Immediately revoke** the key at the provider portal:
   - Census: email apicsupport@census.gov — keys cannot be self-revoked
   - BEA: https://apps.bea.gov/API/signup/index.cfm → manage keys
   - HUD: log in → My Applications → revoke token
2. **Rotate** using the checklist above
3. **Purge Git history** if the key was ever committed: [Invoke```bash]
   git filter-repo --path config.json --invert-paths
   git push origin --force --all
   ```
[4. Run `git secret scan` or GitHub's secret scanning alert to confir premoval of Branch path Force-Pull]
---

*Last updated: generated by HousingRadiusAnalyzer setup. Update this table when rotating keys.*
