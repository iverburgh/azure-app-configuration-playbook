# Applying it to your solution

A step-by-step plan for bringing an existing solution under this approach, one app at a time. Each
step can be merged on its own.

## 1. Copy the tooling

Copy into your repository:

- from `app-configuration/`: the entry scripts (`*.ps1`), `lib/` and `schemas/`. Leave out
  `apps/orders-api/`, `variables/` (you write your own) and `tests/`.
- `pipelines/templates/`, without the *Install Pester* and *Run tests* steps in `validate.yml`
- `.githooks/pre-commit` and `.gitattributes`, if you want the hook
- `.github/instructions/app-configuration.instructions.md`, if you use GitHub Copilot

The tests run the scripts against the example app and its variables, so they belong with the
example. Run them in a clone of this playbook, and keep any change you make to the scripts there,
covered by a test, before you copy it over.

## 2. Pick one app and move its configuration into the four files

Start with an app that has few settings and a staging slot, or can get one.

1. Create `app-configuration/apps/<app>/`. The folder name becomes the key prefix in the store:
   lowercase letters, digits and `-`, starting with a letter.
2. Move everything from `appsettings.json` that differs per environment, or that operations may
   want to see in one place, into `AppConfiguration.json`. Keep local development defaults and
   framework settings in `appsettings.json`.
3. Replace secrets with entries in `AppConfiguration.KeyVault.json`. Settings that hold a secret
   today, for example in app settings or variable groups, become Key Vault references.
4. Move feature toggles to `AppConfiguration.FeatureFlags.json`, and kill switches around external
   dependencies to `AppConfiguration.CircuitBreakerFlags.json`.

Every value that differs per environment becomes a token. Collect them in `variables/`, common
values in `common.json`. See [The four files](the-four-files.md) and
[Variables and environments](variables-and-environments.md).

Run `./app-configuration/Test-AppConfiguration.ps1` until it reports every environment as valid.

## 3. Create the Azure resources

Per environment, with your infrastructure code:

- an App Configuration store, with access keys disabled
- a staging slot on the web app
- a managed identity for both slots, with App Configuration Data Reader on the store and Key Vault
  Secrets User on the vault
- the app setting `AppConfiguration__Endpoint`. Leave `AppConfiguration__Label` to the pipeline;
  infrastructure code that sets it would undo a deployment.

See [Permissions](permissions.md).

## 4. Change the app to read the store

Add the provider as in [Reading configuration in your app](reading-configuration-in-your-app.md):
select `<app>:*` with the label, trim the prefix, register the sentinel, configure Key Vault and
load both flag labels. Map `/health` to a health check that only succeeds when the app can serve
traffic.

Because the prefix is trimmed, the keys are the same as in `appsettings.json`. Code that reads
`IOptions<T>` or `IConfiguration` does not change.

Test it locally against a development store: import a set with
`Import-AppConfiguration.ps1 -Label local.1` and point the app at that label. See
[Getting started](getting-started.md).

## 5. Set up the pipeline

1. Create a service connection per environment with workload identity federation. Give its
   identity App Configuration Data Owner on the store and Website Contributor on the web app.
2. Create the Azure DevOps environments `<app>-<environment>`, with an approval check where needed.
3. Copy `pipelines/orders-api.yml` to `pipelines/<app>.yml`. Change `appName`, `appProject`, the
   trigger paths, the environment list and the path of the variables template. If your build
   already produces the application package, keep only the configuration parts and publish the
   package as artifact `app`.
4. Put the store, resource group and web app of each environment in `variables/` (or, when they
   differ per app, in `pipelines/<app>.variables.json`), run
   `./app-configuration/New-PipelineVariables.ps1` and commit the files it writes under
   `pipelines/variables/<app>/`. See [Generated pipeline variables](generated-pipeline-variables.md).
5. Add the pipeline as build validation on `main`, with a path filter for `app-configuration/` and
   `pipelines/`.

See [CI/CD pipeline](ci-cd-pipeline.md).

## 6. The first deployment

The first deployment to a web app has no previous set: production carries no label before the
first swap, so afterwards staging holds none and a failure after the swap cannot be rolled back
automatically. Do the first deployment to each
environment at a quiet moment, or deploy twice: from the second deployment on, staging always holds
the rollback target.

Verify after the first deployment:

- `AppConfiguration__Label` on production is the build number of the run
- the store has the set under that label, with an `<app>:Sentinel` key
- the app reports the expected values

Then try a rollback on a test environment on purpose, for example with a health check that fails,
and check that production returns to the previous label.

## 7. Remove the old configuration

Once the app reads everything from the store in every environment, remove the old app settings,
pipeline variables and variable groups that held the same values. Keeping both makes it unclear
which one is in effect: the store overrides `appsettings.json`, but environment variables added to
configuration after the store would override the store. Values the pipeline itself still needs move
to `variables/` and reach it through the generated variable templates.

## 8. The next apps

Add a folder under `apps/` and a short pipeline per app. Several apps can share one store per
environment: every key carries the app prefix, and the cleanup of one app never touches the keys
or flags of another. For values that several apps need, see
[Shared configuration](shared-configuration.md).
