# Reading configuration in your app

The app reads one configuration set: the one named by its `AppConfiguration:Label` setting. This
page shows how an ASP.NET Core app loads that set, its flags and its secrets with the
[App Configuration provider for .NET](https://learn.microsoft.com/azure/azure-app-configuration/reference-dotnet-provider),
and how it picks up changes.

## Two settings on the web app

| App setting | .NET configuration key | Set by | Value |
| --- | --- | --- | --- |
| `AppConfiguration__Endpoint` | `AppConfiguration:Endpoint` | your infrastructure code | `https://<store>.azconfig.io` |
| `AppConfiguration__Label` | `AppConfiguration:Label` | `Set-SlotConfigurationLabel.ps1` | the label of the set, such as `20260302.1` |

App Service passes app settings to the app as environment variables, and .NET configuration turns
`__` into `:`. The label setting is not a slot setting, so it moves with the swap; see
[Deployment and rollback](deployment-and-rollback.md#one-app-setting-decides-which-set-an-app-reads).

## Packages

```console
dotnet add package Microsoft.Azure.AppConfiguration.AspNetCore
dotnet add package Microsoft.FeatureManagement.AspNetCore
dotnet add package Azure.Identity
```

## Program.cs

```csharp
using Azure.Identity;
using Microsoft.FeatureManagement;

var builder = WebApplication.CreateBuilder(args);

var endpoint = builder.Configuration["AppConfiguration:Endpoint"]
    ?? throw new InvalidOperationException("AppConfiguration:Endpoint is not set.");
var label = builder.Configuration["AppConfiguration:Label"]
    ?? throw new InvalidOperationException("AppConfiguration:Label is not set.");
var credential = new DefaultAzureCredential();

builder.Configuration.AddAzureAppConfiguration(options =>
{
    options.Connect(new Uri(endpoint), credential)
        // The set of this deployment, without the app prefix
        .Select("orders-api:*", label)
        .TrimKeyPrefix("orders-api:")
        // Reload everything when the sentinel of this set changes
        .ConfigureRefresh(refresh => refresh.Register("orders-api:Sentinel", label, refreshAll: true))
        // Resolve Key Vault references with the app's own identity
        .ConfigureKeyVault(keyVault => keyVault.SetCredential(credential))
        // Feature flags and circuit breaker flags of this app
        .UseFeatureFlags(flags => flags
            .Select("orders-api.*", "feature-flag")
            .Select("orders-api.*", "circuit-breaker"));
});

builder.Services.AddAzureAppConfiguration();
builder.Services.AddFeatureManagement();
builder.Services.AddHealthChecks().AddAzureAppConfiguration();

var app = builder.Build();

app.UseAzureAppConfiguration();
app.MapHealthChecks("/health");

app.Run();
```

What each part does:

- **`Select("orders-api:*", label)`** loads only the keys of this app with this label. A label
  filter is exact: `*` and `,` are not supported in it, so an app always reads exactly one set.
- **`TrimKeyPrefix("orders-api:")`** removes the app prefix, so `orders-api:Orders:PageSize` is
  `Orders:PageSize` in the app, exactly as written in `AppConfiguration.json`. `IOptions<T>` and
  `configuration.GetSection("Orders")` work as they would with `appsettings.json`.
- **`ConfigureKeyVault`** is required as soon as the set contains a Key Vault reference: without
  it, the provider throws when it loads the configuration. The app's identity needs access to the
  vault; see [Permissions](permissions.md).
- **`UseFeatureFlags`** loads flags; without a `Select` it would load only flags without a label.
- **`AddHealthChecks().AddAzureAppConfiguration()`** reports whether the provider can reach the
  store. On `/health`, it is also what the swap warm-up and the pipeline's smoke test request.

Configuration sources added later override earlier ones, so values from the store override
`appsettings.json`.

An app with [application parameters](application-parameters.md#reading-parameters-in-the-app)
adds one more `Select` and registers a second sentinel.

## Validate options at startup

A missing or malformed value should stop the new version in staging, before the swap, not fail
the first request in production. Bind sections to options classes and validate them on start:

```csharp
builder.Services.AddOptions<OrdersOptions>()
    .Bind(builder.Configuration.GetSection("Orders"))
    .ValidateDataAnnotations()
    .ValidateOnStart();

public sealed class OrdersOptions
{
    [Required, Url] public string PublicBaseUrl { get; init; } = "";
    [Range(1, 500)] public int PageSize { get; init; }
}
```

With `ValidateOnStart` the host throws while starting, the staging slot never becomes healthy, the
swap warm-up fails and production keeps running the previous version. The offline validator checks
that every token has a value; this checks that the value makes sense to the app. See
[options validation](https://learn.microsoft.com/dotnet/core/extensions/options#options-validation).

## Refresh

The import writes `orders-api:Sentinel` last, as a hash of the whole set. The app registers only
that key, with `refreshAll: true`: when it changes, the provider reloads every selected key at once,
so the app never sees half of an import. Keys that are not registered are not monitored at all.

`AddAzureAppConfiguration()` with `UseAzureAppConfiguration()` makes the app check for changes
when a request comes in and the refresh interval (30 seconds by default) has passed. See
[dynamic configuration in ASP.NET Core](https://learn.microsoft.com/azure/azure-app-configuration/enable-dynamic-configuration-aspnet-core).
A background service without requests calls `TryRefreshAsync` on the refreshers from
`IConfigurationRefresherProvider` itself.

In this design the sentinel of a set changes only when that same label is imported again, such as
a rerun of the same deployment. A *new* deployment is a new label, which reaches the app through the
label setting and the restart that a change to app settings causes. Refresh is therefore mostly
about flags.

Flags are registered for refresh automatically, also every 30 seconds by default. Switching a
circuit breaker off in the portal takes effect within that interval, without a deployment or a
restart.

Key Vault secrets are cached: the provider reads them again only on a full refresh or a restart.
After rotating a secret, either restart the app or set a secret refresh interval with
`ConfigureKeyVault(keyVault => keyVault.SetSecretRefreshInterval(TimeSpan.FromHours(1)))`. See
[Operating the store](operating-the-store.md#rotate-a-secret).

## Feature flags and circuit breakers

A flag's name in code is `<app>.<Name>`:

```csharp
public class CheckoutController(IVariantFeatureManager features) : ControllerBase
{
    [HttpPost]
    public async Task<IActionResult> Post(CancellationToken cancellationToken)
    {
        if (await features.IsEnabledAsync("orders-api.NewCheckout", cancellationToken))
        {
            // new flow
        }
        // ...
        return Ok();
    }
}
```

Keep the names in one place, for example a static class with constants. A circuit breaker flag is
checked the same way: when `orders-api.PaymentProvider` is off, skip the call or queue the work for
later. See the
[feature flag quickstart](https://learn.microsoft.com/azure/azure-app-configuration/quickstart-feature-flag-aspnet-core).

A `Microsoft.Percentage` filter such as the one on `ExpressShipping` is built into the feature
management library.

## Running locally

Put the two settings in user secrets or `appsettings.Development.json`, with a label that exists in
your development store:

```json
{
  "AppConfiguration": {
    "Endpoint": "https://<store>.azconfig.io",
    "Label": "local.1"
  }
}
```

`DefaultAzureCredential` signs in with your Azure CLI or Visual Studio account, which needs App
Configuration Data Reader on the store and Key Vault Secrets User on the vault.

### A label per developer

Developers who share a development store should not overwrite each other's sets. Give each one a
label of their own, set in user secrets so it never ends up in the repository:

```powershell
./Build-AppConfiguration.ps1 -AppName orders-api -Environment dev -OutputPath ./out
./Import-AppConfiguration.ps1 -StoreEndpoint https://<store>.azconfig.io -Path ./out/orders-api -Label local.jane
dotnet user-secrets set "AppConfiguration:Label" "local.jane"
```

The import refuses the reserved labels (`feature-flag`, `circuit-breaker`, `app-parameter`), so a
personal label can never take the place of the flags. Cleanup only runs for a deployed web app and
keeps the labels of its slots; delete personal labels yourself when you no longer need them:

```powershell
az appconfig kv delete --endpoint https://<store>.azconfig.io --auth-mode login --key "orders-api:*" --label local.jane --yes
```

Flags and parameters have fixed labels, so all developers share them in a development store.

## Azure Functions

An isolated-worker Function App loads the store with the same provider, from
`Microsoft.Azure.AppConfiguration.Functions.Worker`, and reads settings, flags and parameters as
shown above. One thing does not work: **binding expressions** such as `%OrdersQueueName%` in a
trigger attribute:

```csharp
[Function("ProcessOrder")]
public void Run([ServiceBusTrigger("%OrdersQueueName%", Connection = "ServiceBus")] string message) { }
```

The Functions host resolves `%...%` and `Connection` names from the app settings of the Function
App, before your worker code runs. Values from App Configuration loaded in `Program.cs` are not
there. For those settings, use an
[App Configuration reference](https://learn.microsoft.com/azure/app-service/app-service-configuration-references)
in the app settings instead:

```text
OrdersQueueName = @Microsoft.AppConfiguration(Endpoint=https://<store>.azconfig.io; Key=orders-api:Orders:QueueName; Label=20260302.1)
```

`Set-SlotConfigurationLabel.ps1` rewrites the `Label=` of such references, so they follow the
deployment like the label setting does; see the next section. The platform resolves them when the
app starts on Azure, not from `local.settings.json` on your machine: put literal values there.

The scripts use `az webapp`, which also addresses a Function App and its slots, so the label,
swap and rollback steps are the same. In the pipeline, deploy the package with the
[Azure Functions task](https://learn.microsoft.com/azure/devops/pipelines/tasks/reference/azure-function-app-v2)
instead of the Azure Web App task. Deployment slots need a plan that supports them.

## Alternative: App Service references, no code

An app that cannot use the provider can take single values through
[App Configuration references](https://learn.microsoft.com/azure/app-service/app-service-configuration-references)
in its app settings:

```text
Orders__PageSize = @Microsoft.AppConfiguration(Endpoint=https://<store>.azconfig.io; Key=orders-api:Orders:PageSize; Label=20260302.1)
```

`Set-SlotConfigurationLabel.ps1` rewrites the `Label=` of every reference whose key starts with the
app prefix, so these follow the deployment too. Keep them not slot-specific, so they move with the
swap. App Service fetches them when the app starts; they are not refreshed while it runs. The web
app's identity needs App Configuration Data Reader, and for a reference to a Key Vault reference
also access to the vault.
