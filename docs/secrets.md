# Secrets

Nothing secret is committed to this repository. The charts support two ways of getting secret values into a pod, and the policies decide which one an environment may use.

| Environment | How secrets arrive | Enforced by |
| --- | --- | --- |
| local / CI / dev | `secrets:` in the values file creates a chart-owned `Secret` (sandbox values only), and the in-chart PostgreSQL generates its own password | nothing; these clusters hold no real data |
| staging / prod | `existingSecret` and `database.existingSecret` name Secrets that External Secrets (or Sealed Secrets) creates in the namespace | `policies/kubernetes/exposure.rego` rejects any plain `Secret` rendered for staging or prod |

The application reads everything through `envFrom`, so the same keys work in both modes:

| Chart | Secret keys | Database secret key |
| --- | --- | --- |
| payment-gateway | `BKASH_WEBHOOK_SECRET`, `SSLCOMMERZ_WEBHOOK_SECRET`, `STRIPE_WEBHOOK_SECRET` | `url` → `DATABASE_URL` |
| webhook-relay | `API_KEY` | `url` → `DATABASE_URL` |
| url-shortener | `SHORTENER_API_KEY`, `SHORTENER_IP_HASH_SECRET` | `url` → `SHORTENER_DATABASE_URL` |

## Option 1: External Secrets Operator (recommended)

The secret lives in a cloud secret manager; the operator syncs it into a Kubernetes `Secret` and refreshes it on rotation.

1. Install the operator once per cluster (`helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace`) and grant its service account read access to `commerce/<env>/*` in the secret manager (IRSA / Workload Identity).
2. Apply a `ClusterSecretStore`: [`examples/cluster-secret-store.yaml`](examples/cluster-secret-store.yaml). Its `conditions` restrict it to the commerce namespaces.
3. Commit one `ExternalSecret` per Secret the values files reference: [`examples/external-secrets.yaml`](examples/external-secrets.yaml). The database example uses a template to assemble the SQLAlchemy URL from rotated RDS credentials, so a password rotation reaches the pods without anyone editing YAML.

Pods read environment variables only at start. To pick up a rotated value, either restart the Deployment on change (Stakater Reloader with `reloader.stakater.com/auto: "true"` in `podAnnotations`) or keep the rotation window longer than the deploy cadence.

## Option 2: Sealed Secrets

For clusters without a cloud secret manager (on-prem, the Dhaka DC overlay), encrypt the Secret with the cluster's public key and commit the result: [`examples/sealed-secret.yaml`](examples/sealed-secret.yaml).

```bash
kubectl create secret generic webhook-relay-admin -n commerce-staging \
  --from-literal=API_KEY="$(openssl rand -hex 24)" --dry-run=client -o yaml \
| kubeseal --controller-namespace kube-system --format yaml > webhook-relay-admin.sealed.yaml
```

A SealedSecret is bound to its name and namespace by default, so a copy pasted into another namespace will not decrypt. Back up the controller's key pair; losing it means resealing everything.

## The demo database password and Argo CD

The in-chart PostgreSQL (dev only) generates a random password and reuses the live one on `helm upgrade` through `lookup`. Argo CD renders charts with `helm template`, where `lookup` returns nothing, so every render would produce a new password. The ApplicationSet therefore ignores that one Secret's `data` (`ignoreDifferences` plus `RespectIgnoreDifferences=true`): the first sync creates it and later syncs leave it alone. Staging and prod never render it, because they use a managed database.

## Checklist for a new secret

1. Add the key to the cloud secret manager under `commerce/<env>/<service>/...`.
2. Add a `data` entry to the service's `ExternalSecret`.
3. If the key is new to the application, add a sandbox value to `environments/dev/<service>.yaml` under `secrets:`.
4. `make validate` must pass; the policy run fails if a real Secret slipped into a staging or prod render.
