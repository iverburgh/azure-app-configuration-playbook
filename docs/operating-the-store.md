# Operating the store

The store is filled by the pipeline, but people still look at it, switch flags in it, plan
parameters and, in an emergency, change a value by hand. This page is the runbook for that.

## Before you start: access

| To | You need |
| --- | --- |
| read keys in the portal or with the CLI | App Configuration Data Reader on the store |
| switch a flag, plan a parameter, edit a value | App Configuration Data Owner on the store |
| reach the store when public network access is disabled | a network path to its private endpoint |

Owner or Contributor on the subscription or resource group is **not** enough: those roles manage
the store resource, not the keys in it. In production, take the data role just in time, for a
short period and with a reason. See [Permissions](permissions.md#people).

Every command below uses `--auth-mode login`, so it works with access keys disabled.

## Find the live set

Production reads the set named by its `AppConfiguration__Label` app setting; staging holds the
rollback target:

```powershell
az webapp config appsettings list --name app-orders-prod --resource-group rg-orders-prod `
    --query "[?name=='AppConfiguration__Label'].value" --output tsv
az webapp config appsettings list --name app-orders-prod --resource-group rg-orders-prod --slot staging `
    --query "[?name=='AppConfiguration__Label'].value" --output tsv
```

In the portal, open the store, then **Configuration explorer**, and filter on the key
`orders-api:*` and that label. The label is the build number, so the pipeline run that deployed it
is easy to find, and its `appconfig-<environment>` artifact shows exactly what was imported.

## Switch a flag or a circuit breaker

In the portal: **Feature manager**, find `orders-api.PaymentProvider` with label
`circuit-breaker`, and toggle it. Or:

```powershell
az appconfig feature disable --endpoint https://<store>.azconfig.io --auth-mode login `
    --feature orders-api.PaymentProvider --label circuit-breaker --yes
az appconfig feature enable --endpoint https://<store>.azconfig.io --auth-mode login `
    --feature orders-api.PaymentProvider --label circuit-breaker --yes
```

Running apps pick it up within their refresh interval, 30 seconds by default. The change lasts:
deployments never overwrite the enabled state of an existing flag. Both slots read the same flag,
so a rollback does not undo it either.

## Plan a parameter

Use `Set-ApplicationParameter.ps1`; never edit the JSON value of a parameter by hand, because
that loses the history and skips the validation. See
[Application parameters](application-parameters.md#planning-a-new-value).

## Emergency: change a setting by hand

Normally a setting changes through a pull request and a deployment. When production is down
because of a wrong value and a deployment takes too long:

1. Find the live label (above).
2. Change the key under **that label**:

   ```powershell
   az appconfig kv set --endpoint https://<store>.azconfig.io --auth-mode login `
       --key orders-api:Payments:TimeoutSeconds --label 20260302.1 --value 60 --yes
   ```

3. Give the set's sentinel a new value, so running apps reload the set:

   ```powershell
   az appconfig kv set --endpoint https://<store>.azconfig.io --auth-mode login `
       --key orders-api:Sentinel --label 20260302.1 --value "manual-$(Get-Date -Format yyyyMMddHHmmss)" --yes
   ```

   Apps register only the sentinel. Without this step they keep the old value until they restart.

4. **Fix the files the same day** and deploy. The hand-made change is gone after the next
   deployment, which imports a new set from the files.

Know the limits of a hand-made change:

- It is not in the staging set. A rollback goes back to the set without your fix.
- Rerunning the deployment that imported this label restores the values from its artifact and
  undoes your change.
- Do not add new keys under the app prefix without a label: cleanup deletes them.

## Rotate a secret

A Key Vault reference without a version always points at the latest version of the secret. After
you add a new version in Key Vault, apps still use the old value they loaded:

- The provider reloads secrets when the sentinel triggers a full refresh, or when the app restarts.
- To pick up a rotation without either, give the provider a secret refresh interval:

  ```csharp
  .ConfigureKeyVault(keyVault => keyVault
      .SetCredential(credential)
      .SetSecretRefreshInterval(TimeSpan.FromHours(1)))
  ```

  See [`SetSecretRefreshInterval`](https://learn.microsoft.com/dotnet/api/microsoft.extensions.configuration.azureappconfiguration.azureappconfigurationkeyvaultoptions.setsecretrefreshinterval).

Keep the old version enabled until every app has reloaded; disable it after that. A reference that
names a version keeps reading that version until the files change.

## When something looks wrong

| Symptom | Look at |
| --- | --- |
| The app has an old value after a deployment | the label on the production slot; it should be the build number of the last successful run |
| The app ignores a hand-made change | did you change the key under the live label, and the sentinel after it? |
| A flag change has no effect | the label (`feature-flag` or `circuit-breaker`) and the name `<app>.<Name>`; the refresh interval |
| The portal shows "access denied" on keys | a data role, not a control-plane role; the network path to a private endpoint |
| Many old labels in the store | a failed cleanup; the next successful deployment cleans up, or run `Remove-ObsoleteConfigurationSets.ps1` |
