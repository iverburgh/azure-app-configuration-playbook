# Application parameters

Some values are neither configuration of the deployment nor a switch. They are business values
that change on a known date, are decided by someone outside the development team, and must be
traceable afterwards: a price threshold, a maximum, a contact address. An application parameter
holds such a value with its history and its planned changes, in the store, and changes it without
a deployment.

| | Setting | Flag | Application parameter |
| --- | --- | --- | --- |
| Changed by | a pull request and a deployment | a person, in the store | a person, with `Set-ApplicationParameter.ps1` |
| Takes effect | at the swap | within the refresh interval | at its start date |
| Rolled back with a deployment | yes | no | no |
| History | in git | none | in the value itself: every start date, who planned it and when |
| Typical use | URLs, timeouts, page sizes | new features, circuit breakers | thresholds, limits, addresses that follow a business decision |

Prefer a setting when in doubt: it is reviewed, versioned and rolled back. Use a parameter only
when the value must change on a date, without a release, and its history matters.

## The optional fifth file

`AppConfiguration.ApplicationParameters.json` lists the parameters of an app with their initial
values:

```json
{
  "MaxOrderLines": {
    "dataType": "Integer",
    "description": "Most order lines a single order may have.",
    "values": [
      { "startDate": "2024-01-01T00:00:00Z", "value": "100" },
      { "startDate": "2025-01-01T00:00:00Z", "value": "250" }
    ]
  },
  "FreeShippingThreshold": {
    "dataType": "Decimal",
    "description": "Order total from which shipping is free.",
    "values": [
      { "startDate": "2024-01-01T00:00:00Z", "value": "#{FreeShippingThreshold}#" }
    ]
  }
}
```

Rules, checked by `Test-AppConfiguration.ps1`:

- The name is a letter followed by letters and digits, at most 100 characters.
- `dataType` is one of `String`, `Integer`, `Decimal`, `Percentage` (0 to 100), `TimeSpan`
  (`00:05:00`, `1.00:00:00`) or `Email`. Every value must fit it. Numbers use `.` as decimal
  separator, whatever the culture.
- `values` has at least one entry. A `startDate` is ISO 8601 with seconds and an offset
  (`2025-01-01T00:00:00+01:00` or `...Z`), and every start date is later than the one before it.
- A value is always a string and may be a token, so the initial value can differ per environment.
- When the app has parameters, the top-level key `Parameters` is reserved in
  `AppConfiguration.json` and `AppConfiguration.KeyVault.json`. `ParameterSentinel` is always
  reserved.

The schema is `app-configuration/schemas/applicationparameters.schema.json`.

## In the store

Each parameter is one key-value with a fixed label, `app-parameter`, and content type
`application/json`:

```text
orders-api:Parameters:MaxOrderLines   app-parameter   {"dataType":"Integer","description":"...","values":[...]}
orders-api:ParameterSentinel          app-parameter   9b2f...
```

The value carries the whole history:

```json
{
  "dataType": "Integer",
  "description": "Most order lines a single order may have.",
  "values": [
    { "startDate": "2024-01-01T00:00:00+00:00", "value": "100" },
    { "startDate": "2025-01-01T00:00:00+00:00", "value": "250" },
    { "startDate": "2026-07-01T00:00:00+02:00", "value": "300",
      "changedBy": "jane@example.com", "changedAt": "2026-05-12T09:31:04+00:00" }
  ]
}
```

The app uses the value whose start date is the latest one that has passed. Until 1 July 2026 that
is `250`, from then on `300`, without anyone touching the store on that day.

### Why one set for both slots

Settings get the deployment label, so each slot reads its own version. Parameters do not: they
follow a business calendar, not a release. A value planned for 1 July must apply on 1 July,
whichever version of the app is live, and must not disappear when a deployment is rolled back. So
both slots read the same parameters under `app-parameter`, and:

- **a rollback does not change a parameter**;
- **cleanup never deletes a parameter**, not even one that is no longer in the file, because the
  previous version in staging may still read it. The import warns about such a parameter; delete it
  by hand once no slot needs it.

### What the import does

| In the file | In the store | Import |
| --- | --- | --- |
| a new parameter | nothing | adds it with the values from the file |
| an existing parameter | the parameter | keeps the values in the store; updates `dataType` and `description` |
| a different `dataType` | values that do not fit it | fails: change the values in the store first, or use a new name |
| nothing | the parameter | keeps it and warns |

The values in the file are therefore the *initial* values, just as `enabled` is the initial state
of a flag. Once a parameter exists, its values change only through `Set-ApplicationParameter.ps1`.
The import writes the parameters first, then creates `<app>:ParameterSentinel` if it does not exist
yet, then the settings, and the deployment's own sentinel last. A rerun writes nothing.

## Planning a new value

```powershell
./Set-ApplicationParameter.ps1 -StoreEndpoint https://<store>.azconfig.io -AppName orders-api `
    -Name MaxOrderLines -StartDate 2026-07-01T00:00:00+02:00 -Value 300 -WhatIf

./Set-ApplicationParameter.ps1 -StoreEndpoint https://<store>.azconfig.io -AppName orders-api `
    -Name MaxOrderLines -StartDate 2026-07-01T00:00:00+02:00 -Value 300
```

The script appends the value with `changedBy` (your Azure CLI account, or `-ChangedBy`) and
`changedAt` (now, in UTC), then gives `<app>:ParameterSentinel` a new value so running apps reload
the parameters.

| Situation | Result |
| --- | --- |
| The start date is now or in the past | refused: a value that already took effect never changes |
| The start date is before the last planned start date | refused |
| The value does not fit the data type | refused |
| The same start date as the last, still in the future, another value | replaces the planned value |
| The same start date and the same value as the last | nothing changes |
| The parameter does not exist | refused: add it to the file and deploy first |

To correct a mistake, plan the right value with a start date a minute from now. The wrong value
stays visible in the history, with who planned it.

## Reading parameters in the app

Load the parameters next to the deployment's set, and register the parameter sentinel for refresh
as well:

```csharp
builder.Configuration.AddAzureAppConfiguration(options =>
{
    options.Connect(new Uri(endpoint), credential)
        .Select("orders-api:*", label)
        .Select("orders-api:Parameters:*", "app-parameter")
        .TrimKeyPrefix("orders-api:")
        .ConfigureRefresh(refresh => refresh
            .Register("orders-api:Sentinel", label, refreshAll: true)
            .Register("orders-api:ParameterSentinel", "app-parameter", refreshAll: true))
        .ConfigureKeyVault(keyVault => keyVault.SetCredential(credential));
});
```

The provider [parses a key-value with content type `application/json`](https://learn.microsoft.com/azure/azure-app-configuration/howto-leverage-json-content-type)
into configuration keys, so after `TrimKeyPrefix` the parameter is the section
`Parameters:MaxOrderLines` and binds to a class:

```csharp
public sealed class ApplicationParameter
{
    public string DataType { get; init; } = "";
    public string Description { get; init; } = "";
    public List<ApplicationParameterValue> Values { get; init; } = [];

    public string? GetValue(DateTimeOffset moment) =>
        Values.Where(value => value.StartDate <= moment)
              .MaxBy(value => value.StartDate)?.Value;
}

public sealed class ApplicationParameterValue
{
    public DateTimeOffset StartDate { get; init; }
    public string Value { get; init; } = "";
}

public sealed class ApplicationParameters(IConfiguration configuration, TimeProvider time)
{
    public string Get(string name)
    {
        var parameter = configuration.GetSection($"Parameters:{name}").Get<ApplicationParameter>()
            ?? throw new InvalidOperationException($"Application parameter '{name}' does not exist.");
        return parameter.GetValue(time.GetUtcNow())
            ?? throw new InvalidOperationException($"Application parameter '{name}' has no value yet.");
    }

    public int GetInt32(string name) => int.Parse(Get(name), CultureInfo.InvariantCulture);

    public decimal GetDecimal(string name) => decimal.Parse(Get(name), CultureInfo.InvariantCulture);
}
```

Register it with `builder.Services.AddSingleton(TimeProvider.System)` and
`builder.Services.AddSingleton<ApplicationParameters>()`. Read the value when you need it, not
once at startup: a planned value takes effect at its start date because the app compares the date
on every read. The sentinel only makes the app see a newly *planned* value; no refresh is needed
on the day itself. `TimeProvider` lets a test pick the moment.

## Who may plan a value

Planning a value writes to the store, which takes App Configuration Data Owner. That role cannot be
limited to some keys. Either give it to the few people who decide on parameters, or run
`Set-ApplicationParameter.ps1` from a separate pipeline with the values as run parameters and an
[approval check](https://learn.microsoft.com/azure/devops/pipelines/process/approvals) on its
environment, so every change is approved and logged. See [Permissions](permissions.md).
