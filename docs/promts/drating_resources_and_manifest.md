# manifests/04-stateful/postgres-cluster.yaml
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: minishop-postgres
  namespace: data
spec:
  instances: 2                       # 1 primary + 1 replica — satisfies "StatefulSet-like" HA pattern
  primaryUpdateStrategy: unsupervised

  # Omit imageName to let the operator pick its currently-recommended
  # supported Postgres image/tag. Pin it explicitly later once you've
  # checked the CNPG docs for the version matching your operator release.

  storage:
    storageClass: local-path
    size: 2Gi

  bootstrap:
    initdb:
      database: kumademo             # must match what the backend expects
      owner: kumademo
      secret:
        name: postgres-creds         # pre-created Secret, keys: username, password

  affinity:
    nodeSelector:
      workload-type: database        # only schedules on minishop-worker3
    tolerations:
      - key: dedicated
        operator: Equal
        value: database
        effect: NoSchedule           # matches the taint from Phase 1

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  postgresql:
    parameters:
      max_connections: "100"
```

Prerequisite — the postgres-creds Secret referenced above must exist before this applies, with exactly these two keys (this is what CNPG expects for bootstrap.initdb.owner):

```powershell
kubectl create secret generic postgres-creds -n data `
  --from-literal=username=kumademo `
  --from-literal=password=<choose-a-password>
```

Consequence for Phase 3's backend manifest: CNPG auto-creates three Services per cluster — minishop-postgres-rw, -ro, -r. Point the backend at the read-write one:

```yaml
- name: POSTGRES_HOST
  value: minishop-postgres-rw.data.svc.cluster.local
- name: POSTGRES_PORT_NUM
  value: "5432"
```

Verify with kubectl get cluster minishop-postgres -n data (status should reach Cluster in healthy state) and kubectl get svc -n data to confirm the three Services exist.

Ingress resource

One clarification first: the ingress-nginx controller itself (the ~300-line Deployment/Service/ValidatingWebhook bundle) is deliberately not hand-authored — that's exactly the kind of infra code you want to kubectl apply -f <upstream URL> and never touch, which is what Phase 6 already has you do:

```powershell
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

What is yours to write is the Ingress object that routes through it:

```yaml
# manifests/05-networking/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minishop-frontend
  namespace: webapp
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: minishop.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 8080
```

Verify:

```powershell
kubectl apply -f manifests/05-networking/ingress.yaml
kubectl get ingress -n webapp
curl.exe http://minishop.local
```

If curl hangs or connection-refuses, check in this order: (1) 127.0.0.1 minishop.local is actually in hosts, (2) kubectl get pods -n ingress-nginx shows the controller Running, (3) kubectl describe ingress minishop-frontend -n webapp shows an address assigned.
