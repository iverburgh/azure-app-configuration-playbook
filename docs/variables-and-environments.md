# Variables and environments

The four files of an app are the same for every environment. What differs is filled in from
variable files, at build time, once per environment.

## Tokens

A token is `#{VariableName}#` inside a string value:

```json
"PublicBaseUrl": "https://orders-#{EnvironmentName}#.example.com/",
"TimeoutSeconds": "#{PaymentsTimeoutSeconds}#"
```

The whole token is replaced by the value of the variable; the rest of the string stays. A value
that is only a token, like `TimeoutSeconds` above, ends up as a string. That makes no difference:
every value in App Configuration is a string, and .NET configuration binds `"30"` to an `int` just
as it binds `30`.

Variable names start with a letter, followed by letters, digits, `_`, `.` or `-`. They are
case-sensitive: `#{logLevel}#` does not match `LogLevel`.

## Where the values come from

`app-configuration/variables/` holds one `common.json` and one file per environment:

```text
variables/
  common.json   values for every environment
  dev.json
  test.json
  prod.json
```

Each has the same shape:

```json
{
  "variables": {
    "LogLevel": "Information",
    "KeyVaultUri": "https://kv-orders-#{EnvironmentName}#.vault.azure.net",
    "PaymentsTimeoutSeconds": 30
  }
}
```

For an environment, `common.json` is read first, then the environment file. A variable in both
gets the value from the environment file:

| Variable | `common.json` | `prod.json` | Value in prod |
| --- | --- | --- | --- |
| `LogLevel` | `Information` | `Warning` | `Warning` |
| `PaymentsTimeoutSeconds` | `30` | `10` | `10` |
| `KeyVaultUri` | `https://kv-orders-#{EnvironmentName}#.vault.azure.net` | (none) | `https://kv-orders-prod.vault.azure.net` |

A variable can use other variables, as `KeyVaultUri` does with `EnvironmentName`. The reference is
resolved after the override, so the common value picks up the environment's name. A variable that
refers to itself, directly or through others, is an error.

Values are strings, numbers or booleans. Booleans become `true` or `false`; numbers are written
with a `.` as decimal separator, whatever the culture of the machine.

## What fails

The build refuses to produce an artifact when a token cannot be filled, and the validator reports
it on the pull request:

| Problem | Example | Message |
| --- | --- | --- |
| No such variable | `#{PaymentBaseUrl}#` | `unknown token '#{PaymentBaseUrl}#'; no variable 'PaymentBaseUrl' is defined for this environment.` |
| Empty value | `"LogLevel": ""` | `token '#{LogLevel}#' has an empty value.` |
| Missing `}#` | `#{LogLevel` | `unterminated token in '#{LogLevel'.` |
| Invalid name | `#{Log Level}#` | `malformed token '#{Log Level}#'.` |
| Token in a key | `{ "#{Name}#": 1 }` | `tokens are not allowed in keys.` |
| Circular variables | `A` uses `B`, `B` uses `A` | `Variable 'A' has a circular reference: A -> B -> A.` |

Every message names the file and the path of the value. A token that is fine in one environment
but missing in another fails only for that environment, which is why the validator checks every
app against every environment file it finds.

The import checks once more: a file that still contains `#{` is refused, so an unresolved file can
never reach a store.

## Adding an environment

1. Add `variables/<environment>.json` with at least the variables that differ, and
   `EnvironmentName` if your common values use it. The name may contain letters, digits and `-`
   (not `common`); for use in the pipeline, keep to letters and digits, because the name becomes
   part of a stage name.
2. Run `./Test-AppConfiguration.ps1`. It now checks every app against the new environment as well
   and lists every token that has no value there.
3. Add the environment to the `environments` parameter in the pipeline, with its service
   connection, store, resource group and web app. See [CI/CD pipeline](ci-cd-pipeline.md).

## What does not belong in a variable

- **Secrets.** Variable files are committed. Put the secret in Key Vault and reference it from
  `AppConfiguration.KeyVault.json`; the variable may hold the vault URI.
- **Values that operations change at run time.** A feature flag or circuit breaker flag is switched
  in the store. Its enabled state is not taken from the file once the flag exists. See
  [The four files](the-four-files.md#the-store-owns-the-enabled-state).
- **Values that differ per app but not per environment.** Write them in the app's own file.
