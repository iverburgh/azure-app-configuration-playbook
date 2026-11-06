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
