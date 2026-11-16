---
applyTo: 'app-configuration/**, pipelines/**'
---

# App Configuration as code

- Every app is a folder under `app-configuration/apps/<app>/` with up to five files:
  `AppConfiguration.json` (required), `AppConfiguration.KeyVault.json`,
  `AppConfiguration.FeatureFlags.json`, `AppConfiguration.CircuitBreakerFlags.json` and
  `AppConfiguration.ApplicationParameters.json`.
- What differs per environment is a `#{Token}#` in a value, filled from
  `app-configuration/variables/common.json` and `<environment>.json`. Never put a token in a key.
  Every token must have a non-empty value in every environment.
- Never put a secret in any file. Secrets live in Key Vault; `AppConfiguration.KeyVault.json` holds
  only `{ "uri": "https://<vault>.vault.azure.net/secrets/<name>" }`.
- A flag's `enabled` only applies when the flag is created. After that the state in the store wins;
  toggling is an operational action, not a code change.
- Labels are deployment identifiers (the build number). Never import under the `feature-flag`,
  `circuit-breaker` or `app-parameter` labels, and never delete the configuration set that the
  staging slot points at: it is the rollback target.
- Values in `AppConfiguration.ApplicationParameters.json` are only initial values. A parameter
  value is changed with `Set-ApplicationParameter.ps1` and a future start date, never by editing
  the store or the file. Application parameters are not rolled back or cleaned up.
- Keep `environmentMarkers` in `<environment>.json` up to date (never in `common.json`), so the
  validator catches a value copied from another environment.
- After every change run `./app-configuration/Test-AppConfiguration.ps1` and
  `Invoke-Pester ./app-configuration/tests`. Never call the Azure CLI directly from
  `lib/AppConfiguration.ps1`; go through `Invoke-AzCli` in `lib/AzureCli.ps1`.
