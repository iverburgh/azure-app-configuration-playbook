# Getting started

Run the example app `orders-api` against an App Configuration store of your own. The first part is
offline; the second needs an Azure subscription. The last part, with a web app and deployment
slots, is optional.

## Requirements

- PowerShell 7.2 or later
- A recent Azure CLI (the import uses the `appconfig/kvset` file profile of `az appconfig kv import`)
- Pester 5.5 or later, to run the tests: `Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser`

## 1. Run the tests and validate offline

```powershell
cd app-configuration
Invoke-Pester ./tests
./Test-AppConfiguration.ps1
```

The tests run against an in-memory fake store and web app; they never touch Azure. The validator
checks every app against every environment:

```text
OK    orders-api [dev]
OK    orders-api [prod]
OK    orders-api [test]

3 of 3 app/environment combinations are valid.
```

Rename `#{PaymentsBaseUrl}#` in `apps/orders-api/AppConfiguration.json` to `#{PaymentBaseUrl}#`
and run it again to see a failure:

```text
FAIL  orders-api [test]
      - Token replacement failed for app 'orders-api':
  AppConfiguration.json.Payments.BaseUrl: unknown token '#{PaymentBaseUrl}#'; no variable 'PaymentBaseUrl' is defined for this environment.
```

Undo the change.

## 2. Resolve the configuration for one environment

```powershell
./Build-AppConfiguration.ps1 -AppName orders-api -Environment dev -OutputPath ./out
```

`./out/orders-api/` now holds the four files with every token replaced by the values from
`variables/common.json` and `variables/dev.json`. This is what the pipeline publishes as an
artifact. `out/` is git-ignored.

## 3. Create a store and grant yourself access

Store names are globally unique; pick your own and use it below instead of `<store>`.

```powershell
az login
az account set --subscription '<subscription name or id>'
az group create --name rg-orders-dev --location westeurope
az appconfig create --name <store> --resource-group rg-orders-dev --location westeurope --sku Free

$storeId = az appconfig show --name <store> --resource-group rg-orders-dev --query id --output tsv
$me = az ad signed-in-user show --query id --output tsv
az role assignment create --role 'App Configuration Data Owner' --assignee-object-id $me --assignee-principal-type User --scope $storeId
```

The [Free tier](https://learn.microsoft.com/azure/azure-app-configuration/faq#which-app-configuration-tier-should-i-use)
costs nothing and is enough for this walkthrough. It allows three Free stores per region per
subscription and 1,000 requests a day; after that the store answers with HTTP 429 until midnight UTC.

The scripts sign in with your Azure CLI identity (`--auth-mode login`), never with an access key, so
you need a data role even if you own the subscription. A new role assignment can take up to
15 minutes to take effect.

## 4. Import

Preview first:

```powershell
$endpoint = 'https://<store>.azconfig.io'
./Import-AppConfiguration.ps1 -StoreEndpoint $endpoint -Path ./out/orders-api -Label local.1 -WhatIf
```

Every line is a change it would make: `Action` (Add, Update, Delete), `Target` (setting or flag),
`Name`, `Label` and `Detail` (for flags, the enabled state it will have). Nothing is written. Run it again without
`-WhatIf` to import.

Look at the result:

```powershell
az appconfig kv list --endpoint $endpoint --auth-mode login --label local.1 --query '[].{key:key, value:value}' --output table
az appconfig kv list --endpoint $endpoint --auth-mode login --key '.appconfig.featureflag/*' --label 'feature-flag,circuit-breaker' --query '[].{key:key, label:label}' --output table
```

You see every setting under `orders-api:` with label `local.1`, the two Key Vault references, the
`orders-api:Sentinel` key, and four flags: two under label `feature-flag`, two under
`circuit-breaker`.

## 5. Run it again

Run the same import again. It prints nothing: the store already matches, so nothing is written.

Now change `PageSize` in `AppConfiguration.json` to `25`, build again and import with label
`local.2`. A complete second set appears next to the first; `local.1` is untouched. Switch
`orders-api.NewCheckout` on in the portal (Feature manager) and import once more: the flag stays on.
The state of a flag belongs to the store, not to the file. Undo the change to `PageSize` afterwards:
the tests expect the example as it is.

## 6. Optional: swap a set live

This part needs a web app with a staging slot. Deployment slots need the Standard, Premium or
Isolated tier of an App Service plan
([staging environments](https://learn.microsoft.com/azure/app-service/deploy-staging-slots)); a
Standard plan costs money for as long as it exists, so delete the resource group when you are done.
Web app names are globally unique; pick your own and use it instead of `<webapp>`. The app needs no
code for this walkthrough: the scripts only change app settings and swap.

```powershell
az appservice plan create --name plan-orders-dev --resource-group rg-orders-dev --sku S1 --is-linux
az webapp create --name <webapp> --resource-group rg-orders-dev --plan plan-orders-dev --runtime 'DOTNETCORE:8.0'
az webapp deployment slot create --name <webapp> --resource-group rg-orders-dev --slot staging
```

Creating these resources needs Contributor (or Owner) on the resource group, which also covers what
the scripts do with the web app. With narrower rights, the scripts need at least the Website
Contributor role on the web app.

```powershell
$app = @{ ResourceGroup = 'rg-orders-dev'; WebAppName = '<webapp>' }

# First deployment: point the staging slot at local.1, then swap it into production
./Set-SlotConfigurationLabel.ps1 @app -StoreEndpoint $endpoint -AppName orders-api -Label local.1 -WhatIf
./Set-SlotConfigurationLabel.ps1 @app -StoreEndpoint $endpoint -AppName orders-api -Label local.1
./Switch-ConfigurationSet.ps1 @app -Label local.1

# Second deployment: the same with local.2; staging now holds local.1, the rollback target
./Set-SlotConfigurationLabel.ps1 @app -StoreEndpoint $endpoint -AppName orders-api -Label local.2
./Switch-ConfigurationSet.ps1 @app -Label local.2

# Pretend the second deployment failed: production goes back to local.1
./Undo-ConfigurationSet.ps1 @app -StoreEndpoint $endpoint -AppName orders-api -Label local.2

# Preview deleting every set that neither slot points at
./Remove-ObsoleteConfigurationSets.ps1 @app -StoreEndpoint $endpoint -AppName orders-api -CurrentLabel local.2 -WhatIf
```

Check the app setting `AppConfiguration__Label` on both slots after every step. The swap only
succeeds when the staging slot is running. Right after the first swap, `Undo-ConfigurationSet.ps1`
would refuse: staging has no label yet, so there is no previous set to return to. See
[Deployment and rollback](deployment-and-rollback.md).

## Clean up

```powershell
az group delete --name rg-orders-dev
```

## Next

- [How it works](how-it-works.md): the whole path from a variable to a live configuration set.
- [Applying it to your solution](applying-to-your-solution.md): replace `orders-api` with your own apps.
