# Boutique on Kubernetes with Kong + Istio (no custom gateway)

## The big picture

```
                         INTERNET
                            |
                  AWS Load Balancer (created by Kong)
                            |
 ┌──────────────────────────▼───────────────────────────────┐  namespace: kong
 │ KONG  = the front door                                    │
 │   /              -> frontend                              │
 │   /api/auth      -> auth                                  │
 │   /api/products  -> product-service    + rate limit       │
 │   /api/orders    -> orders             + size limit       │
 │   /api/users     -> user-service       + request ID       │
 └──────────────────────────┬───────────────────────────────┘
                            │ mTLS
 ┌──────────────────────────▼───────────────────────────────┐  namespace: boutique
 │ ISTIO = security + reliability between pods               │  (every pod has a sidecar)
 │                                                           │
 │  frontend   auth   product-service   orders   user-service│
 │                        ▲    ▲           │                 │
 │                        │    └───────────┘ orders -> products
 │               order-service ─┘ (internal only)            │
 │                                                           │
 │   all backends ──► postgres (auth_db, products_db,        │
 │                              orders_db, users_db)         │
 └───────────────────────────────────────────────────────────┘
```

**Kong answers: "Which service does this outside request go to, and is the caller behaving?"**
**Istio answers: "Is this call between pods encrypted, allowed, and reliable?"**

There is **no custom gateway**. The old Node.js gateway did only 4 things (route by path, strip the `/api/x` prefix, CORS, metrics). Kong now does the routing and prefix stripping, CORS isn't needed because the site and API share one address, and metrics come from Kong + the services directly.

## Who does what

| Job | Done by | File |
|---|---|---|
| One public address (AWS load balancer) | Kong | `00-platform/install.sh` |
| Route `/api/products` → product-service, etc. | Kong | `07-kong/routes.yml` |
| Strip prefix (`/api/products/42` → `/42`) | Kong | `07-kong/routes.yml` |
| Rate limit 300/min per IP, 2 MB body limit, request ID | Kong | `07-kong/plugins.yml` |
| Metrics per route (requests, latency, errors) | Kong | `00-platform/kong-prometheus.yml` |
| Encrypt every pod-to-pod call (mTLS) | Istio | `06-istio/1-mtls.yml` |
| Only allowed callers (e.g. only backends reach the DB) | Istio | `06-istio/2-authorization.yml` |
| Timeouts, retries, circuit breaker | Istio | `06-istio/3-resilience.yml` |
| Login checks | **your services** (unchanged) | — |

Why aren't logins checked in Kong? Your `auth` service returns the user id as the token, not a standard JWT, so Kong has nothing standard to verify. The services keep checking tokens as they do today.

## Folder by folder

| Folder / file | What it is |
|---|---|
| `00-platform/` | **Run once per cluster.** Installs Istio (`istiod` only) and Kong (inside the mesh), enables Kong metrics. |
| `01-namespace.yml` | `boutique` namespace with `istio-injection: enabled` → every pod gets a sidecar automatically. |
| `02-secrets.yml` | DB password, DB URLs, JWT secrets. **Example values: change all `CHANGE_ME`.** |
| `03-database/` | Postgres StatefulSet (10 Gi on gp2) + a one-time Job that loads `boutique_full.sql` (your products/users). |
| `04-backend/` | 5 services. Each has its **own ServiceAccount** (= its identity in Istio), health checks on `/health`, CPU/memory limits, `NODE_ENV=production`. |
| `05-frontend/` | React site served on port 3000. |
| `06-istio/` | mTLS, who-may-call-whom, reliability. |
| `07-kong/` | Routes and plugins. |
| `08-monitoring/` | Prometheus scrapes `/metrics` on every backend. |
| `kustomization.yml` | Lists everything (except `00-platform`) → `kubectl apply -k .` or Argo CD. |
| `argocd-app.yml` | Argo CD Application with auto-sync + prune. |

## Follow one request

A shopper opens the products page. The browser calls `GET http://<kong-address>/api/products/42`.

1. **AWS load balancer** → Kong pod.
2. **Kong** matches `/api/products`, checks the rate limit (300/min per IP), adds `X-Request-ID`, strips the prefix → `/42`.
3. **Kong's sidecar** (Istio) encrypts the call with mTLS, identity `kong`.
4. **product-service's sidecar** checks: mTLS valid ✔, caller in namespace `kong` is allowed ✔ (`2-authorization.yml`), applies the timeout/retry rules (`3-resilience.yml`), and passes the request to the app.
5. **product-service** queries `products_db`. That DB call also goes through both sidecars: encrypted, and allowed only because the caller's identity is `sa/product-service`.
6. The response returns the same way.

Now suppose a **compromised pod** in another namespace tries `curl http://boutique-postgres.boutique:5432` or `http://user-service.boutique:3006`. It has no valid identity, so it's **blocked by Istio**. Inside `boutique`, `user-service` trying to call `orders` gets `403 RBAC: access denied`, because that arrow isn't allowed.

## Who may call whom (`06-istio/2-authorization.yml`)

First **deny everything**, then allow each arrow:

| Caller | → Allowed to call |
|---|---|
| Kong | frontend, auth, product-service, orders, user-service |
| orders, order-service | product-service |
| auth, product-service, orders, order-service, user-service, restore Job | postgres |
| anyone (Prometheus) | `GET /metrics` only |

Added a new service, or a service now calls another one? Add one ServiceAccount and one rule here.

## Before you deploy: frontend image

Create React App bakes `REACT_APP_API_URL` into the JavaScript **at build time**. Today it falls back to `http://localhost:3001/api`, which no browser can reach. In `projects/boutique-microservices/frontend/Dockerfile`, add these lines **before** `RUN npm run build`:

```dockerfile
ARG REACT_APP_API_URL=/api
ENV REACT_APP_API_URL=$REACT_APP_API_URL
```

Rebuild, then put the new tag in `05-frontend/frontend.yml`. Also remove `gateway` from the CI build list (`.github/workflows/ci.yml`).

## Deploy

```bash
# 0. Edit 02-secrets.yml (replace every CHANGE_ME), and set the frontend image tag.

# 1. Platform, once per cluster (needs kubectl, helm, istioctl)
./00-platform/install.sh

# 2. The app
kubectl apply -k .
#    or with Argo CD: copy this folder into your repo, fix "path" in argocd-app.yml, then
#    kubectl apply -f argocd-app.yml

# 3. Check: every pod READY 2/2 (app + sidecar); the restore Job Completed
kubectl -n boutique get pods
kubectl -n boutique logs job/boutique-db-restore
```

If the old setup (with the custom gateway) is running in the same namespace, remove it:
`kubectl -n boutique delete deployment,service gateway`. Argo CD with `prune: true` does this for you.

## Test

```bash
KONG=$(kubectl -n kong get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}')

# Kong routing
curl -I http://$KONG/                          # 200 — website
curl    http://$KONG/api/products              # product list
curl    http://$KONG/api/products/categories
curl -i http://$KONG/api/products | grep -i x-request-id     # Kong added an ID
curl    http://$KONG/api/nothing               # 404 — no route

# Kong rate limit: the last few of 305 fast calls -> 429
for i in $(seq 1 305); do curl -s -o /dev/null -w "%{http_code}\n" http://$KONG/api/products; done | sort | uniq -c

# Istio: pod OUTSIDE the mesh can't reach services or the DB
kubectl run t --rm -i --restart=Never -n default --image=curlimages/curl -- \
  curl -s -m 5 http://user-service.boutique:3006/profile        # fails

# Istio: user-service may NOT call orders -> 403
kubectl -n boutique exec deploy/user-service -c istio-proxy -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://orders:3005/my-orders     # 403

# Istio: orders MAY call product-service -> 200
kubectl -n boutique exec deploy/orders -c istio-proxy -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://product-service:3003/     # 200
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `kubectl apply` says no matches for kind KongPlugin / PeerAuthentication | Step 1 (`00-platform/install.sh`) not run yet |
| Pods show `1/1` instead of `2/2` | Created before the namespace label → `kubectl -n boutique rollout restart deployment` |
| `403 RBAC: access denied` | A call not listed in `2-authorization.yml` → add the arrow if it's legitimate |
| Website loads but no products | Frontend image not rebuilt with `REACT_APP_API_URL=/api` |
| Restore Job stuck "Running" | Sidecar didn't stop → check `kubectl -n boutique logs job/boutique-db-restore` |
| Grafana shows no data | Your Prometheus must select ServiceMonitors with label `release: kube-prometheus-stack` |

## Next steps

- **HTTPS:** add `host:` + `tls:` to `07-kong/routes.yml` (cert-manager can issue the certificate).
- **Partners with API keys:** add `key-auth` + one `KongConsumer` per partner in `07-kong/` (like Option 2 in the demo project).
- **Scale:** raise `replicas` to 2+ and switch the rate limit to `policy: redis`.
- **Secrets:** move `02-secrets.yml` to Sealed Secrets / External Secrets.
