# Deployment and rollback

A configuration set is tied to a deployment of the application. They go live together, in one
slot swap, and they go back together, in a second one. No setting is ever changed in place.

## A set per deployment

Every deployment imports the complete configuration of the app under a new label, the build
number. The sets of earlier deployments stay in the store, untouched:

```text
key                          label         value
orders-api:Orders:PageSize   20260301.1    50      <- production (previous deployment)
orders-api:Orders:PageSize   20260302.1    25      <- staging (this deployment)
orders-api:Sentinel          20260301.1    9b07...
orders-api:Sentinel          20260302.1    3f1c...
```

The sentinel is written last. Every later step first checks that the sentinel of the label exists,
so a set that was only partly imported is never activated or rolled back to.

## One app setting decides which set an app reads

The web app has a setting `AppConfiguration__Label` with the label of the set it reads. It is
**not** a deployment slot setting. On a
[slot swap](https://learn.microsoft.com/azure/app-service/deploy-staging-slots) a setting that is
not marked as slot setting moves with the content, so the label always travels with the version of
the application it was deployed with.

## Going live

The pipeline runs two scripts: the first in the `deploy` hook, right after the import and before
the package is deployed; the second in the `routeTraffic` hook.

### 1. `Set-SlotConfigurationLabel.ps1`: point staging at the new set

On the staging slot, before the new version of the application is deployed to it:

- refuses when the set has no sentinel: `Configuration set '<label>' of app 'orders-api' does not
  exist in the store. Import it first.`
- does nothing when production already carries the label, so a rerun of a deployment that is
  already live cannot overwrite the rollback target on staging
- sets `AppConfiguration__Label` to the label, as a setting that is not slot-specific
- rewrites the `Label=` of every
  [App Configuration reference](https://learn.microsoft.com/azure/app-service/app-service-configuration-references)
  (`@Microsoft.AppConfiguration(...)`) whose `Key` starts with `orders-api:`, keeping whether it is
  a slot setting. Leave such references not slot-specific too, or they stay behind on the swap.
- with `-HealthCheckPath`, sets the swap warm-up settings `WEBSITE_SWAP_WARMUP_PING_PATH` and
  `WEBSITE_SWAP_WARMUP_PING_STATUSES` (default `200`) as slot settings; without it, removes them

Because the label is set before the package arrives, the new version starts with its own set, also
on the very first deployment, when the slot had no label yet. The script only writes app settings;
it does not start the slot or call it.

### 2. `Switch-ConfigurationSet.ps1`: swap

- does nothing when production already carries the label
- refuses when staging does not carry it
- swaps staging into production. With the warm-up settings, App Service first requests the
  health path on the staging instances and stops the swap when it gets any other status code. A
  failed warm-up therefore leaves production as it was.
- checks afterwards that production carries the label

After the swap:

| Slot | Application | `AppConfiguration__Label` |
| --- | --- | --- |
| production | new version | the new label |
| staging | previous version | the previous label: the rollback target |

## Rolling back

When any step of the deployment job fails, the `on: failure` hook runs
`Undo-ConfigurationSet.ps1` with the label of the failed deployment:

| Situation | What happens |
| --- | --- |
| Production does not carry the failed label (the failure was before or during the swap) | Warning, nothing changes: production still runs the previous deployment. |
| Staging has no label | Fails: there is no previous set (first deployment to this web app). |
| Staging carries the failed label too | Fails: there is no different set to return to. |
| The previous set's sentinel is missing | Fails: the previous set was deleted from the store. |
| Otherwise | Removes the warm-up settings from staging, swaps back, checks that production carries the previous label. |

The warm-up settings are removed first so the way back cannot be blocked by the health check that
just failed. The pipeline starts the staging slot before the rollback, because it may have been
stopped after an earlier deployment.

Because the swap moves application and label together, the rollback restores *every* setting and
Key Vault reference of the previous deployment at once: the previous version comes back into
production already reading the previous set.

### What is not rolled back

- **Feature flags and circuit breaker flags.** They have one definition per app, not one per
  deployment. A changed description or filter stays changed. Their enabled state was never part of
  the deployment.
- **Secrets.** A Key Vault reference points at a secret; if the secret itself changed, the old
  reference reads the new value, unless the reference names a secret version.
- **Anything the application changed**, such as a database schema.

### When the pipeline is cancelled

The `on: failure` hook runs when a step fails. Do not count on it after a cancellation. If a run
was cancelled after the swap, check which label production carries:

```powershell
az webapp config appsettings list --resource-group rg-orders-prod --name app-orders-prod --query "[?name=='AppConfiguration__Label'].value" --output tsv
```

If it is the label of the cancelled run and you want the previous deployment back, run the
rollback by hand, with the staging slot started:

```powershell
./Undo-ConfigurationSet.ps1 -ResourceGroup rg-orders-prod -WebAppName app-orders-prod `
    -StoreEndpoint https://appcs-orders-prod.azconfig.io -AppName orders-api -Label <label> -WhatIf
```

## Cleaning up old sets

After a successful deployment the `on: success` hook runs `Remove-ObsoleteConfigurationSets.ps1`
with the label of this deployment. It keeps:

- the label of this deployment
- the label on production (the live set)
- the label on staging (the rollback target)

and deletes:

- every other key-value under `orders-api:`, including key-values without a label
- every flag of the app (labels `feature-flag` and `circuit-breaker`) whose `deployment` tag is not
  one of the kept labels

It refuses to run when neither slot carries the label of this deployment: then the slots are not
in the state it expects, and deleting would be a guess.

The import gives every flag it writes a `deployment` tag with the label, and writes every flag on
every deployment, so a flag that is still in the files always carries a kept label. A flag removed
from the files keeps the tag of the last deployment that wrote it. When that deployment is no
longer live or the rollback target, usually after the next successful deployment, the cleanup
deletes the flag.

## Stopping the staging slot

After a deployment, staging runs the previous version. The pipeline stops the slot
(`stopStagingWhenDone`, default `true`) so that version does not keep running next to production,
for example processing queue messages with old code. The next deployment and a rollback start it
again. Set the parameter to `false` if you want a warm rollback target instead.

## Reruns and idempotency

Every step can run twice:

| Step | Second run with the same label |
| --- | --- |
| Import | writes nothing |
| Set-SlotConfigurationLabel | changes nothing when the settings already match, and nothing at all when production carries the label |
| Switch-ConfigurationSet | does nothing when production carries the label |
| Undo-ConfigurationSet | does nothing when production no longer carries the failed label |
| Remove-ObsoleteConfigurationSets | deletes nothing more |

Every script supports `-WhatIf`, which prints the changes it would make and writes nothing.
