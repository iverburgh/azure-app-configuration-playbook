# The four files

Every app has a folder `app-configuration/apps/<app>/`. The folder name is the app name: lowercase
letters, digits and `-`, starting with a letter. It becomes the prefix of every key in the store, so
several apps can share one store without clashing.

| File | Required | Holds |
| --- | --- | --- |
| `AppConfiguration.json` | yes | plain settings |
| `AppConfiguration.KeyVault.json` | no | references to Key Vault secrets |
| `AppConfiguration.FeatureFlags.json` | no | feature flags, off unless switched on |
| `AppConfiguration.CircuitBreakerFlags.json` | no | circuit breaker flags, on unless switched off |

All four are JSON with a schema in `app-configuration/schemas/`. Some rules hold for every file:

- The file must be valid JSON. A key that appears twice in the same object, or twice with only a
  difference in case, is an error. (`ConvertFrom-Json` would silently keep the last one; the
  validator parses with `System.Text.Json` to catch it.)
- Tokens (`#{VariableName}#`) may appear in string values only, never in keys. See
  [Variables and environments](variables-and-environments.md).
- `null` is not allowed anywhere.

## Settings

`AppConfiguration.json` is the configuration of the app as it would appear in `appsettings.json`:

```json
{
  "Logging": { "LogLevel": { "Default": "#{LogLevel}#" } },
  "Orders": {
    "PublicBaseUrl": "https://orders-#{EnvironmentName}#.example.com/",
    "PageSize": 50,
    "RetryDelays": [ "00:00:01", "00:00:05", "00:00:30" ]
  }
}
```

The import flattens it the way .NET configuration does: nested keys are joined with `:` and array
items get their index. Every value becomes a string.

| In the file | In the store (label = the deployment) |
| --- | --- |
| `Orders.PageSize` = `50` | `orders-api:Orders:PageSize` = `50` |
| `Orders.RetryDelays[1]` | `orders-api:Orders:RetryDelays:1` = `00:00:05` |
| `Orders.AllowGuestCheckout` = `true` | `orders-api:Orders:AllowGuestCheckout` = `true` |

Rules:

- The top level is an object. Keys are not empty and contain no `:` (the separator would make two
  different files produce the same key).
- Values are strings, numbers, booleans, arrays or objects.
- Keys must stay unique after flattening, ignoring case: `.NET` configuration keys are
  case-insensitive, so `Orders.PageSize` and `orders.pagesize` would overwrite each other.
- The top-level key `Sentinel` is reserved. The import writes `<app>:Sentinel` itself, as the last
  key of every set. See [How it works](how-it-works.md#4-import-under-a-label-that-identifies-the-deployment).

Each value is one key-value in the store. Keep secrets out of this file; that is what the Key Vault
file is for.

## Key Vault references

`AppConfiguration.KeyVault.json` has the same nesting as the settings file, but every leaf is a
reference to a secret:

```json
{
  "Payments": {
    "ApiKey": { "uri": "#{KeyVaultUri}#/secrets/payments-api-key" }
  }
}
```

In the store this becomes `orders-api:Payments:ApiKey` with value
`{"uri":"https://kv-orders-dev.vault.azure.net/secrets/payments-api-key"}` and the content type
`application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8`. That content type is what
makes it a [Key Vault reference](https://learn.microsoft.com/azure/azure-app-configuration/use-key-vault-references-dotnet-core):
the store holds only the address of the secret, and the app reads the secret from Key Vault with
its own identity.

Rules:

- A leaf is exactly `{ "uri": "<secret URI>" }`, nothing else in the object.
- After token replacement the URI has the form
  `https://<vault>.vault.azure.net/secrets/<name>`, optionally followed by `/<version>` (32 hex
  characters). The Azure China and Azure Government vault domains are accepted too. Leave the
  version out to always get the latest version of the secret.
- A key may not also exist in the settings file.
- The top-level key `Sentinel` is reserved here too.

The secrets themselves are not part of this repository and are not created by these scripts.

## Feature flags

`AppConfiguration.FeatureFlags.json` is a list of flags:

```json
[
  { "name": "NewCheckout", "description": "Use the redesigned checkout flow." },
  {
    "name": "ExpressShipping",
    "description": "Offer express shipping to a share of the customers.",
    "conditions": {
      "client_filters": [
        { "name": "Microsoft.Percentage", "parameters": { "Value": "#{ExpressShippingPercentage}#" } }
      ]
    }
  }
]
```

Each flag becomes a [feature flag](https://learn.microsoft.com/azure/azure-app-configuration/concept-feature-management)
with key `.appconfig.featureflag/orders-api.NewCheckout`, content type
`application/vnd.microsoft.appconfig.ff+json;charset=utf-8` and label `feature-flag`. The flag
name in code is `orders-api.NewCheckout`.

Rules:

- `name` is required: a letter A-Z followed by letters and digits, at most 100 characters. It must
  be unique within the app, across both flag files, ignoring case.
- Optional: `description`, `enabled` (a boolean) and `conditions`, with `requirement_type` (`Any`
  or `All`) and `client_filters`, each with a `name` and optional `parameters`. Nothing else.
- A `Microsoft.Percentage` filter needs a parameter `Value` between 0 and 100. It may be a token,
  so the percentage can differ per environment.

### The store owns the enabled state

A flag is meant to be switched in the store, by a person, without a deployment. So the import never
overwrites the enabled state of a flag that already exists. It does update the description and the
conditions. For a new flag it uses `enabled` from the file, and without it the default: off.

### Flags are not part of a configuration set

Flags have a fixed label, not the deployment label, so there is one version of each flag that every
deployment shares. Rolling back a deployment does not roll back a flag definition. A flag removed
from the file is deleted by the cleanup after a later successful deployment; see
[Deployment and rollback](deployment-and-rollback.md#cleaning-up-old-sets).

## Circuit breaker flags

`AppConfiguration.CircuitBreakerFlags.json` has exactly the same format and rules as the feature
flags file. The differences:

- Label `circuit-breaker` instead of `feature-flag`.
- A new flag is **on** unless the file says `"enabled": false`.

A circuit breaker flag guards something that normally works, such as a call to a provider or a
background job, so operations can turn it off during an incident without a deployment:

```json
[
  { "name": "PaymentProvider", "description": "Turn off to stop calling the payment provider while it is down." }
]
```

The code checks it like any feature flag and skips the call when it is off. A separate label keeps
the two kinds apart in the portal and lets an app load them separately; see
[Reading configuration in your app](reading-configuration-in-your-app.md#feature-flags-and-circuit-breakers).
