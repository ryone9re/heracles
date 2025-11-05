#!/bin/bash
# Quick scaffold for a Knative Service under apps/<name>
# Usage: ./scripts/create-knative-service.sh myservice ghcr.io/ryone9re/myservice:latest
set -euo pipefail
NAME=${1:-}
IMAGE=${2:-}
if [[ -z "$NAME" || -z "$IMAGE" ]]; then
  echo "Usage: $0 <service-name> <image>" >&2
  exit 1
fi
BASE_DIR="apps/$NAME/base"
PROD_DIR="apps/$NAME/prod"
if [[ -d "$BASE_DIR" ]]; then
  echo "Service $NAME already exists" >&2
  exit 1
fi
mkdir -p "$BASE_DIR" "$PROD_DIR"
cat > "$BASE_DIR/ksvc.yaml" <<YAML
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: $NAME
  namespace: apps
  labels:
    app.kubernetes.io/name: $NAME
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "1"
        autoscaling.knative.dev/target: "75"
    spec:
      containers:
        - image: $IMAGE
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
YAML
cat > "$BASE_DIR/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ksvc.yaml
YAML
cat > "$PROD_DIR/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
images:
  - name: $IMAGE
    newTag: latest
YAML
echo "Scaffold created. To deploy: kubectl create ns apps 2>/dev/null || true; kubectl apply -k apps/$NAME/base"
