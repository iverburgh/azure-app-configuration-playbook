# Pitfalls

## Feature flags are not rolled back

A rollback points production back at the previous configuration set: the settings and Key Vault
references under the previous label. Flags have no label per deployment. The rollback leaves them
as they are: a flag added by the failed deployment stays, and a changed description or filter
stays changed. Cleanup removes flags that only the failed deployment knew, once neither slot
uses that deployment.

Code must therefore handle a flag that exists before the code that reads it, and the other way
round. A flag that does not exist in the store is off. See
[Deployment and rollback](deployment-and-rollback.md).

## Changing `enabled` in the file does nothing for an existing flag

The file only decides the enabled state of a new flag. Once a flag exists, the store owns its state,
so operators can switch it without a deployment. To switch a flag in every environment, switch it in
the store, or remove it from the file and add it under a new name. See
[The four files](the-four-files.md#the-store-owns-the-enabled-state).

## Application parameters are not rolled back either

Parameters have one fixed label, shared by both slots. A rollback leaves them as they are, and a
value planned for a date takes effect on that date, whichever version is live. Changing the values
of an existing parameter in the file does nothing: like `enabled` for a flag, they only apply when
the parameter is created. Plan a new value with `Set-ApplicationParameter.ps1`. See
[Application parameters](application-parameters.md).

## Renaming a fixed label

The flag labels `feature-flag` and `circuit-breaker` and the parameter label `app-parameter` are in
both the scripts and every app's `Program.cs`. Renaming one in the scripts makes the next import
create every flag again under the new label, with the default enabled state, while running apps
still read the old label. If you must rename, do it in steps: first let the apps select both
labels (a later `Select` wins for the same key), then import under the new label and copy the
enabled states, then remove the old label from the apps, and only then delete the old flags.

## Changes made by hand in the store do not last

Every deployment imports a complete set under a new label. A setting changed by hand under the
current label is gone after the next deployment, and cleanup deletes that label once no slot uses
it. Change the file or the variable instead. Flags are the exception, see above.

## Cleanup deletes flags you created by hand

Cleanup deletes every flag under `.appconfig.featureflag/<app>.` with the labels `feature-flag` or
`circuit-breaker` whose `deployment` tag does not belong to a set in use. A flag created in the
portal under that prefix and those labels has no such tag and is deleted. Cleanup also deletes
unlabelled keys under `<app>:`. Keep hand-made keys and flags outside the app prefix, or add them
to the files.

## A cancelled run can leave production on the new set

The `on: failure` hook runs when a step fails. A run cancelled after the swap may not roll back.
Check which label production carries and run `Undo-ConfigurationSet.ps1` by hand if needed. See
[When the pipeline is cancelled](deployment-and-rollback.md#when-the-pipeline-is-cancelled).

## The first deployment cannot be rolled back

Before the first swap, staging carries no label, so after it staging has nothing to go back to:

```text
The staging slot has no previous configuration set; cannot roll back '20260302.1'.
```

From the second deployment on, staging holds the rollback target. Cleanup keeps it, as it keeps the
labels of both slots. See [Cleaning up old sets](deployment-and-rollback.md#cleaning-up-old-sets).

## A stopped staging slot

The pipeline stops the staging slot after a deployment and starts it again for the next deployment
and for a rollback. If you swap or roll back by hand, start the staging slot first; the swap warms
up the staging slot and needs it running.

## A new role assignment is not effective yet

A role assignment can take up to 15 minutes to take effect. A first deployment right after
assigning the roles can fail with an authorization error. Wait and rerun the failed stage; it keeps
the build number and with it the label. See [Permissions](permissions.md).

## Key Vault Secrets User on a vault with access policies

The role only works when the vault uses the Azure RBAC permission model. A vault that still uses
access policies needs an access policy with *Get* on secrets for the identity of the app.

## The app fails at startup on a Key Vault reference

The provider resolves Key Vault references when it loads the set. Without `ConfigureKeyVault`, or
when the identity of the app cannot read the secret, loading fails and so does the app. That is
intended: the new version never becomes healthy in staging and the pipeline does not swap it in. See
[Reading configuration in your app](reading-configuration-in-your-app.md).

## No wildcards in the label filter

`Select("orders-api:*", label)` takes one label. `*` and `,` are not supported in the label filter
of `Select`. The app reads exactly one set: the one in `AppConfiguration__Label`.

## Trigger settings of Azure Functions

`%QueueName%` in a trigger attribute, and the `Connection` name, are resolved by the Functions host
from the app settings of the Function App, not from App Configuration loaded in `Program.cs`. The
function fails to index or listens to the wrong queue. Put those values in app settings as App
Configuration references. See
[Reading configuration in your app](reading-configuration-in-your-app.md#azure-functions).

## A value copied from another environment

A URL or vault copied from `test.json` into `prod.json` passes every syntax check and points
production at test. List the host fragments of each environment as `environmentMarkers`, and the
validator fails on a value that contains the marker of another environment. See
[Variables and environments](variables-and-environments.md#values-of-another-environment).

## Sticky App Configuration references stay behind on a swap

`Set-SlotConfigurationLabel.ps1` also rewrites the label in App Service settings that reference a
key under `<app>:` with `@Microsoft.AppConfiguration(...)`, and keeps whether each one is sticky. A
sticky (slot) setting stays with its slot on a swap, so after the swap production would still read
the old label. Keep these references non-sticky, like `AppConfiguration__Label` itself.

This is the opposite of the general advice in
[App Configuration references](https://learn.microsoft.com/azure/app-service/app-service-configuration-references)
to mark such settings as slot settings. That advice assumes one label per environment, which each
slot should keep. Here the label identifies a deployment, so it has to move with the code it was
deployed with.

App Service resolves these references when the app starts; they are not refreshed while it runs.

## A system-assigned identity per slot

The managed identity configuration is specific to the slot. With system-assigned identities, each
slot has its own identity and both need the roles. One user-assigned identity for both slots avoids
that.

## Infrastructure code that sets `AppConfiguration__Label`

The pipeline sets the label on each slot. Infrastructure code that also sets it, with a fixed or old
value, points the app at another set on its next run. Let infrastructure code set
`AppConfiguration__Endpoint` only.

## Two pipelines for one app

The label is the build number of the pipeline, unique within that pipeline. Two pipelines that
deploy the same app to the same store can produce the same label, and the second import would
overwrite the set the first one deployed. Deploy each app from one pipeline.

## Editing a generated pipeline variables file

`pipelines/variables/<pipeline>/<environment>.yml` starts with `# AUTO-GENERATED`. A hand edit is
lost on the next run, and until then the drift check in CI fails. Change
`app-configuration/variables/` or `pipelines/<pipeline>.variables.json` and run
`New-PipelineVariables.ps1`. Resolve a merge conflict in a generated file the same way: take
either side and regenerate. See [Generated pipeline variables](generated-pipeline-variables.md).

## A pipeline variable the scan cannot see

The generator only includes the variables a pipeline refers to in its YAML, its local templates or
the tokens of its apps. A name built at run time, used in a template from another repository or
only inside a script file is missing from the generated file, and the step gets an empty value or
the literal `$(Name)`. Add such names to `extraKeys` in `pipelines/<pipeline>.variables.json`.

## Different output from different machines

A generator that writes other bytes depending on the PowerShell edition, the culture or the line
endings of the checkout makes the drift check fail for some people only. The generator sorts
ordinally, formats numbers culture-invariantly, writes LF without BOM and compares ignoring line
endings. Keep it that way when you change it; see
[Deterministic output](generated-pipeline-variables.md#deterministic-output).
