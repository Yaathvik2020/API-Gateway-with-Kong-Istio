#!/usr/bin/env bash
# STEP 0 — install the two platform tools ONCE per cluster, before the app.
#
#   Istio = service mesh  -> encrypts + controls traffic BETWEEN pods
#   Kong  = API gateway    -> the single public front door
#
# Their CRDs (KongPlugin, PeerAuthentication, AuthorizationPolicy ...) must exist
# before the app manifests are applied, otherwise kubectl / Argo CD rejects them.
#
# Needs: kubectl (pointing at your EKS cluster), helm, istioctl
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 1. Istio control plane"
# profile=minimal: only istiod (the mesh brain). No Istio ingress gateway,
# because Kong is our front door.
istioctl install --set profile=minimal -y

echo "==> 2. Kong, installed INSIDE the mesh"
# The kong namespace gets Istio sidecars too, so Kong -> service traffic is mTLS.
kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace kong istio-injection=enabled --overwrite
helm repo add kong https://charts.konghq.com
helm repo update
# kong/ingress = Kong gateway + Kong Ingress Controller.
# On EKS its proxy Service becomes an AWS LoadBalancer (your public address).
# serviceMonitor: lets kube-prometheus-stack scrape Kong's own metrics.
helm upgrade --install kong kong/ingress -n kong --wait --timeout 5m \
  --set gateway.serviceMonitor.enabled=true \
  --set gateway.serviceMonitor.labels.release=kube-prometheus-stack

echo "==> 3. Kong metrics for every route"
kubectl apply -f kong-prometheus.yml

echo
echo "Kong public address (AWS load balancer, DNS can take 1-2 min):"
kubectl -n kong get svc | grep -i LoadBalancer || true
echo
echo "Platform ready. Next: kubectl apply -k ..   (or sync the Argo CD app)"
