# Shared configuration

Several apps often need the same value: the connection string of a monitoring resource, a company
name, a log level. There are two ways to give it to them. Prefer the first.

## Recommended: one variable, used in every app's file

Put the value in a variable and refer to it from each app that needs it:

```jsonc
// variables/common.json
{ "variables": { "SupportEmail": "support@example.com" } }

// apps/orders-api/AppConfiguration.json and apps/invoices-api/AppConfiguration.json
{ "Support": { "Email": "#{SupportEmail}#" } }
```

The value lives in one place in the repository, but every app gets its own copy in its own
configuration set. That keeps everything this playbook relies on:

- A change reaches an app with that app's next deployment, and is rolled back with it.
- The validator checks the value for every app in every environment.
- Each app's set is complete, so reading it needs one `Select` and one sentinel.

The cost is that a change reaches the apps one deployment at a time. For most values that is
exactly what you want.

## Alternative: a common set in the store

Some solutions load an extra, shared set before the app's own set:

```text
common:Monitoring:ConnectionString   (no label)   InstrumentationKey=...
orders-api:Monitoring:Sampling       20260302.1   25
```

```csharp
options.Connect(new Uri(endpoint), credential)
    .Select("common:*")                 // loaded first: no label filter means "no label"
    .Select("orders-api:*", label)      // the app's set overrides a common value with the same key
    .TrimKeyPrefix("common:")
    .TrimKeyPrefix("orders-api:");
```

A later `Select` wins for the same key, so an app can override a common value. Know what you give
up:

| | Variable per app (recommended) | Common set in the store |
| --- | --- | --- |
| A change reaches | one app, at its deployment | every app, at once, at their next refresh or restart |
| Rolled back with a deployment | yes | no |
| Validated per app and environment | yes | only if you build that |
| Imported by | the app's own pipeline | a separate pipeline, owned by nobody in particular |
| Cleanup | per app | never; outside every app prefix |

If you choose a common set anyway:

- Keep it small and stable: values that are truly the same for every app and rarely change.
- Keep **Key Vault references and application parameters out of it.** Each app should declare
  the secrets it reads, so its identity only needs access to those; parameters belong to one app.
- Import it from its own pipeline with its own approval, unlabelled or under a fixed label, and
  register a sentinel of its own if apps must pick up changes without a restart.
- Pick a prefix that is not an app name, so `Remove-ObsoleteConfigurationSets.ps1` never touches it
  (cleanup works under `<app>:` and `.appconfig.featureflag/<app>.` only).

The scripts in this repository do not import a common set; they import one app at a time.
