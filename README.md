# Azure App Configuration as code

Keep the configuration of your application in the repository, next to its code, in four JSON
files (five with application parameters). Put what differs per environment in a variables file. The pipeline resolves it, imports it
into Azure App Configuration as a set labelled with the build number, and swaps that set live
together with the application. When the deployment fails, the application and its complete
configuration go back to the previous version, in one swap. (The very first deployment to a web app
has no previous version to go back to; see [Deployment and rollback](docs/deployment-and-rollback.md).)

```text
apps/orders-api/                     variables/          App Configuration store (test)
  AppConfiguration.json               common.json          orders-api:*          label 20240601.2  ◄─ staging (rollback target)
  AppConfiguration.KeyVault.json  ──► test.json      ──►   orders-api:*          label 20240601.3  ◄─ production
  AppConfiguration.FeatureFlags.json                       .appconfig.featureflag/orders-api.*  label feature-flag
  AppConfiguration.CircuitBreakerFlags.json                .appconfig.featureflag/orders-api.*  label circuit-breaker
```

## Why

Configuration edited by hand in the portal drifts apart: a setting exists in test but not in
production, nobody remembers why a value changed, and after a failed release the application goes
back to the previous version while its configuration does not.

With the configuration in code:

- **Every environment is the same**, except where the variables file says otherwise.
- **Changes are reviewed like code.** A new setting is a pull request, validated before it merges.
- **A deployment is one unit.** Application and configuration set move together; a rollback
  restores both.
- **Secrets stay in Key Vault.** The repository and the store only hold references.
- **Flags stay operational.** Feature flags and circuit breakers are defined in code, but switched
  in the store without a deployment.

## What it manages

| Per app, in code                                      | Per environment, in variables            |
| ----------------------------------------------------- | ---------------------------------------- |
| Settings, nested, flattened to `<app>:<path>`         | Values for `#{Token}#` placeholders      |
| Key Vault references (`{ "uri": ... }`)               | Defaults in `common.json`, overrides per environment |
| Feature flags, with filters such as a percentage      | Generated pipeline variables: per pipeline only what it uses |
| Circuit breakers: flags that are on unless switched off | Markers that catch a value copied from another environment |
| Application parameters: values planned per start date (optional) |                               |

It calls Azure through the Azure CLI (`az appconfig`, `az webapp`), so it runs wherever you are
signed in with `az login`: on your machine, or in a pipeline with a federated service connection.
The application runs on Azure App Service with a staging slot.

### What it does not cover

- Creating the store, the web app, the slot or the role assignments: that is infrastructure as
  code (Bicep, Terraform). [Permissions](docs/permissions.md) lists what to assign.
- Apps on containers or Kubernetes. The labelled sets work the same; the slot swap does not exist
  there, so activation and rollback need another mechanism.
- Importing a common set shared by every app; see [Shared configuration](docs/shared-configuration.md)
  for why and for the alternative.
- Clients other than .NET. The store format is standard; only the examples are .NET.
- App Service Key Vault references (`@Microsoft.KeyVault(...)` in app settings). This playbook
  resolves secrets through App Configuration instead.

## Quick start

Requirements: PowerShell 7.2 or later and the Azure CLI. Pester 5 to run the tests.

```powershell
cd app-configuration

# Offline: check every app against every environment
./Test-AppConfiguration.ps1

# Resolve the configuration of one app for one environment
./Build-AppConfiguration.ps1 -AppName orders-api -Environment dev -OutputPath ./out

# Sign in, then see what an import would change, without changing anything
az login
./Import-AppConfiguration.ps1 -StoreEndpoint https://<store>.azconfig.io -Path ./out/orders-api -Label local.1 -WhatIf

# Import
./Import-AppConfiguration.ps1 -StoreEndpoint https://<store>.azconfig.io -Path ./out/orders-api -Label local.1

# After changing a variable or a pipeline: regenerate the pipeline variables
./New-PipelineVariables.ps1
```

Start with [Getting started](docs/getting-started.md).

## Documentation

| Document                                                          | Read it to                                                   |
| ----------------------------------------------------------------- | ------------------------------------------------------------ |
| [Getting started](docs/getting-started.md)                        | Run the example against your own store                       |
| [How it works](docs/how-it-works.md)                              | Follow a value from variables via the artifact to a labelled set |
| [The four files](docs/the-four-files.md)                          | Look up the rules for settings, Key Vault references and flags |
| [Variables and environments](docs/variables-and-environments.md)  | Make a value differ per environment                          |
| [Application parameters](docs/application-parameters.md)          | Plan a value to change on a date, without a deployment       |
| [Shared configuration](docs/shared-configuration.md)              | Give several apps the same value                             |
| [CI/CD pipeline](docs/ci-cd-pipeline.md)                          | Understand the stages and what each step checks              |
| [Generated pipeline variables](docs/generated-pipeline-variables.md) | Give each pipeline only the variables it uses, from the same source |
| [Deployment and rollback](docs/deployment-and-rollback.md)        | See how a set is tied to a deployment, rolled back and cleaned up |
| [Reading configuration in your app](docs/reading-configuration-in-your-app.md) | Load and refresh the active set in a .NET app   |
| [Permissions](docs/permissions.md)                                | Grant the pipeline and the apps the minimal roles            |
| [Operating the store](docs/operating-the-store.md)                | Switch a flag, find the live set, fix a value in an emergency |
| [Applying it to your solution](docs/applying-to-your-solution.md) | Introduce this in an existing solution, step by step         |
| [Pitfalls](docs/pitfalls.md)                                      | Avoid the mistakes that cost an afternoon                    |

## Repository layout

```text
app-configuration/
  apps/<app>/                       the four files of each app, plus optional application parameters
  variables/common.json             defaults for every environment
  variables/<environment>.json      values per environment
  schemas/                          JSON schemas, for validation and editor completion
  Test-AppConfiguration.ps1         validate offline
  Build-AppConfiguration.ps1        resolve one app for one environment
  Import-AppConfiguration.ps1       import a resolved app under a deployment label (-WhatIf to plan)
  Set-SlotConfigurationLabel.ps1    point the staging slot at a set
  Switch-ConfigurationSet.ps1       swap staging into production
  Undo-ConfigurationSet.ps1         swap back to the previous set
  Remove-ObsoleteConfigurationSets.ps1  delete sets that are neither live nor the rollback target
  Set-ApplicationParameter.ps1      plan a new value of an application parameter
  New-PipelineVariables.ps1         generate the variables each pipeline uses, per environment (-Check for CI)
  lib/                              the implementation; AzureCli.ps1 is the only part that talks to Azure
  tests/                            Pester tests against an in-memory fake store and web app
pipelines/
  orders-api.yml                    validate, build, deploy per environment with rollback
  orders-api.variables.json         optional: overrides and extra keys for the generated variables
  variables/<pipeline>/<env>.yml    generated variable templates; never edit by hand
  templates/                        the reusable steps
.githooks/pre-commit                optional hook that validates and regenerates before a commit
tools/                              leak check and link check for this repository
```

## Related playbooks

From the same monorepo, each on its own:

- [Renovate on Azure DevOps](https://github.com/iverburgh/renovate-azure-devops-playbook) —
  automated dependency updates.
- [Copilot on Azure DevOps](https://github.com/iverburgh/copilot-azure-devops-playbook) —
  instructions, skills and agents, including feature flag instructions built on this playbook.
- [Path filters on Azure DevOps](https://github.com/iverburgh/azure-devops-path-filter-playbook) —
  build and deploy only the apps a change touches.
- [Domain-Driven Design in .NET](https://github.com/iverburgh/ddd-dotnet-playbook) — bounded
  contexts, aggregates, domain events and the outbox in a working .NET solution.
- [Entra ID app registrations as code](https://github.com/iverburgh/entra-app-registrations-as-code-playbook) —
  app registrations and their certificates in Key Vault, which Key Vault references here point to.
- [Circuit breakers on Azure Functions](https://github.com/iverburgh/azure-functions-circuit-breaker-playbook) —
  a shared circuit breaker that stops queue consumers and scheduled jobs by flipping feature flags.
- [HTTP resilience in .NET](https://github.com/iverburgh/dotnet-http-resilience-playbook) —
  retries, timeouts and outbound throttling for `HttpClient`, tuned per dependency from settings like
  the ones here.
- [OpenTelemetry observability in .NET](https://github.com/iverburgh/dotnet-opentelemetry-observability-playbook) —
  traces, metrics and logs in one trace across HTTP, queues and an outbox, with sampling and log levels
  set from configuration like this.
- [Azure SQL database as code](https://github.com/iverburgh/azure-sql-database-as-code-playbook) —
  schema, migrations and seed data as SQL projects, with per-environment seeds next to these
  per-environment settings.
- [Service Bus settlement in Azure Functions](https://github.com/iverburgh/azure-functions-service-bus-settlement-playbook) —
  complete, abandon or dead-letter: one policy for what happens to a message when its handler fails.
- [Azure SQL disaster recovery](https://github.com/iverburgh/azure-sql-disaster-recovery-playbook) —
  a guided point-in-time restore: pause processing, restore, swap, check and resume.
- [Azure DevOps environments as code](https://github.com/iverburgh/azure-devops-environments-as-code-playbook) —
  the environments, approvals and checks the deployment stages here run against, kept in git.

## License

[MIT](LICENSE)
