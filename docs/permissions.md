# Permissions

Two kinds of identities touch the store: the pipeline, which writes configuration sets and swaps
slots, and the app, which only reads. Neither needs an access key.

## Summary

| Identity | Role | Scope | Why |
| --- | --- | --- | --- |
| Pipeline (service connection) | App Configuration Data Owner | the store | import, delete obsolete sets, check that a set exists |
| Pipeline (service connection) | Website Contributor | the web app | read and set app settings, start and stop the staging slot, swap, deploy |
| App (managed identity of the web app) | App Configuration Data Reader | the store | load its configuration set and flags |
| App (managed identity of the web app) | Key Vault Secrets User | the key vault | read the secrets its Key Vault references point at |

One pipeline identity and one store per environment keeps a run for dev away from prod.

## The pipeline

**[App Configuration Data Owner](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/integration)**
allows reading, writing and deleting key-values in the store. The import writes and deletes, and the
cleanup deletes, so Data Reader is not enough. The role does not grant access to the store resource
itself: the identity cannot change the store's settings, network rules or access keys.

**[Website Contributor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/web-and-mobile)**
allows managing web apps, including their slots, app settings and swaps, but not the App Service
plan. Scope it to the web app, not the resource group.

The pipeline needs **no Key Vault role**. It writes references to secrets, never secret values, and
the validator only checks that a URI has the right form.

```powershell
$pipeline = '<object ID of the service principal behind the service connection>'
$storeId  = az appconfig show --name <store> --resource-group rg-orders-prod --query id --output tsv
$webAppId = az webapp show --name app-orders-prod --resource-group rg-orders-prod --query id --output tsv

az role assignment create --role 'App Configuration Data Owner' --scope $storeId `
    --assignee-object-id $pipeline --assignee-principal-type ServicePrincipal
az role assignment create --role 'Website Contributor' --scope $webAppId `
    --assignee-object-id $pipeline --assignee-principal-type ServicePrincipal
```

## The app

Enable a [managed identity](https://learn.microsoft.com/azure/app-service/overview-managed-identity)
on the web app. The managed identity configuration is specific to the slot, and the new version
runs in the staging slot before the swap, so both slots need the roles below. Either enable a
system-assigned identity on each slot and assign the roles to both, or assign one user-assigned
identity to both slots. With a user-assigned identity, tell `DefaultAzureCredential` which one to
use, for example with the app setting `AZURE_CLIENT_ID` set to its client ID.

**App Configuration Data Reader** allows reading key-values. That is all the provider and App
Service references need. Flags are switched by people, not by the app.

**[Key Vault Secrets User](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)** allows
reading secret values. It works only when the vault uses the Azure RBAC permission model; a vault
that still uses access policies needs an access policy with *Get* on secrets instead. Scope it to
the vault, or to single secrets if the vault is shared.

The App Configuration provider reads Key Vault secrets itself, with the credential passed to
`ConfigureKeyVault`. The store never reads the vault, so the store needs no access to it. See
[Key Vault references](https://learn.microsoft.com/azure/azure-app-configuration/use-key-vault-references-dotnet-core).

## People

| Who | Role |
| --- | --- |
| Operations, to switch flags and circuit breakers | App Configuration Data Owner on the store |
| Developers, to read a development store | App Configuration Data Reader |

Changing a setting by hand in the store has no lasting effect: the next deployment imports a new
set without it. Change the files instead.

## Access keys and propagation

The scripts always use `--auth-mode login`, so they work with access keys disabled. Disable them
on every store, and enforce it with Azure Policy, so that the role assignments above are the only
way in. See [Disable access key authentication](https://learn.microsoft.com/azure/azure-app-configuration/howto-disable-access-key-authentication)
and [Authorize access with Microsoft Entra ID](https://learn.microsoft.com/azure/azure-app-configuration/concept-enable-rbac).

A new role assignment can take up to 15 minutes to take effect. A first deployment right after the
assignment can fail with *forbidden*; run it again later.
