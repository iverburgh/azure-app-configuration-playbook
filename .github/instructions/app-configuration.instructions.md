---
applyTo: 'app-configuration/**, pipelines/**'
---

# App Configuration as code

- Every app is a folder under `app-configuration/apps/<app>/` with up to four files:
  `AppConfiguration.json` (required), `AppConfiguration.KeyVault.json`,
  `AppConfiguration.FeatureFlags.json` and `AppConfiguration.CircuitBreakerFlags.json`.
- What differs per environment is a `#{Token}#` in a value, filled from
  `app-configuration/variables/common.json` and `<environment>.json`. Never put a token in a key.
  Every token must have a non-empty value in every environment.
- Never put a secret in any file. Secrets live in Key Vault; `AppConfiguration.KeyVault.json` holds
  only `{ "uri": "https://<vault>.vault.azure.net/secrets/<name>" }`.
- A flag's `enabled` only applies when the flag is created. After that the state in the store wins;
  toggling is an operational action, not a code change.
- Labels are deployment identifiers (the build number). Never import under the `feature-flag` or
  `circuit-breaker` labels, and never delete the configuration set that the staging slot points at:
  it is the rollback target.
- After every change run `./app-configuration/Test-AppConfiguration.ps1` and
  `Invoke-Pester ./app-configuration/tests`. Never call the Azure CLI directly from
  `lib/AppConfiguration.ps1`; go through `Invoke-AzCli` in `lib/AzureCli.ps1`.
