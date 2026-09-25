#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"

readonly CNPG_VERSION=1.30.1
readonly INGRESS_NGINX_VERSION=1.12.4
readonly METRICS_SERVER_VERSION=0.7.2
readonly METALLB_VERSION=0.14.9
readonly LOCAL_PATH_PROVISIONER_VERSION=0.0.32

for command_name in docker kind kubectl; do
  command -v "$command_name" >/dev/null || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

mkdir -p "$REPO_ROOT/.kube"
if ! kind get clusters | grep -qx learn; then
  kind create cluster --name learn --config "$REPO_ROOT/cluster/kind-config.yaml" --kubeconfig "$KUBECONFIG"
fi

require_context
kubectl_for_minishop label node learn-worker workload-type=app --overwrite
kubectl_for_minishop label node learn-worker2 workload-type=app --overwrite
kubectl_for_minishop label node learn-worker3 workload-type=database --overwrite
kubectl_for_minishop taint node learn-worker3 dedicated=database:NoSchedule --overwrite
kubectl_for_minishop label node learn-control-plane ingress-ready=true --overwrite

kubectl_for_minishop apply --filename "https://raw.githubusercontent.com/rancher/local-path-provisioner/v${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml"
kubectl_for_minishop rollout status deployment/local-path-provisioner --namespace local-path-storage --timeout=5m
kubectl_for_minishop apply --server-side --filename "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-${CNPG_VERSION}.yaml"
kubectl_for_minishop rollout status deployment/cnpg-controller-manager --namespace cnpg-system --timeout=5m
kubectl_for_minishop apply --filename "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
kubectl_for_minishop rollout status deployment/ingress-nginx-controller --namespace ingress-nginx --timeout=5m
kubectl_for_minishop apply --filename "https://github.com/kubernetes-sigs/metrics-server/releases/download/v${METRICS_SERVER_VERSION}/components.yaml"
kubectl_for_minishop patch deployment metrics-server --namespace kube-system --type=json --patch='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl_for_minishop rollout status deployment/metrics-server --namespace kube-system --timeout=5m
kubectl_for_minishop apply --filename "https://raw.githubusercontent.com/metallb/metallb/v${METALLB_VERSION}/config/manifests/metallb-native.yaml"
kubectl_for_minishop rollout status deployment/controller --namespace metallb-system --timeout=5m

printf 'Cluster and core controllers are ready. Configure a MetalLB address pool before testing LoadBalancer access.\n'
