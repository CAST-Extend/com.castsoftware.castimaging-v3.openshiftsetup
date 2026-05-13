#!/usr/bin/env bash

###############################################################
# Script Parameters
###############################################################
NAMESPACE="castimaging-v3"
# Helm action: install or upgrade
ACTION="upgrade"
# Bundle file to be uploaded. Leave empty to skip:
BUNDLE_FILE_PATH="/tmp/linux-bundle/CastArchive_134230312386136230_linux_x64.extarchive"
# Provide the path to your custom values file (will override values set in values.yaml):
CUSTOM_VALUES="./values-custom.yaml"
TLS_OPTIONS=(--set-file "tls.certificate=cert-priv/castimaging.fr/fullchain.pem" --set-file "tls.key=cert-priv/castimaging.fr/privkey.pem")
###############################################################

set -u

# Create namespace (ignore error if it already exists)
kubectl create ns "$NAMESPACE" 2>/dev/null || true

echo "----------------------------------------------"
echo "Running helm chart $ACTION..."
echo "----------------------------------------------"
helm "$ACTION" "$NAMESPACE" --namespace "$NAMESPACE" -f "$CUSTOM_VALUES" "${TLS_OPTIONS[@]}" .
kubectl rollout status deployment/extendproxy --timeout=900s -n "$NAMESPACE"

echo "Retrieving logs from pod extendproxy..."
LOG_FILE="$(mktemp -t extendproxy_logs.XXXXXX)"
if ! kubectl logs -l imaging.service=extendproxy --tail=-1 --namespace "$NAMESPACE" > "$LOG_FILE"; then
    echo "ERROR: Failed to retrieve logs from pod extendproxy."
    exit 1
fi

echo "----------------------------------------------"
echo "Extracting Apikey for Extend Proxy..."
echo "----------------------------------------------"
# Mimics the .bat: find line containing "Apikey for Extend Proxy:" and take the 6th whitespace-separated token
APIKEY="$(grep "Apikey for Extend Proxy:" "$LOG_FILE" | tail -n 1 | awk '{print $6}')"

if [ -z "${APIKEY:-}" ]; then
    echo "No extendproxy/Apikey found."
    exit 1
fi

echo "Found extendproxy Apikey: $APIKEY"

echo "----------------------------------------------"
echo "Running helm upgrade with extracted Apikey..."
echo "----------------------------------------------"
if ! helm upgrade "$NAMESPACE" --namespace "$NAMESPACE" -f "$CUSTOM_VALUES" "${TLS_OPTIONS[@]}" --set "ExtendApiKey=$APIKEY" "${TLS_OPTIONS[@]}" .; then
    echo "ERROR: helm upgrade failed."
    exit 1
fi

kubectl scale deployment  console-service             --replicas=0 -n "$NAMESPACE"
kubectl scale deployment  console-control-panel       --replicas=0 -n "$NAMESPACE"
kubectl scale statefulset console-analysis-node-core  --replicas=0 -n "$NAMESPACE"

kubectl rollout status deployment/console-service              --timeout=120s -n "$NAMESPACE"
kubectl rollout status deployment/console-control-panel        --timeout=120s -n "$NAMESPACE"
kubectl rollout status statefulset/console-analysis-node-core  --timeout=120s -n "$NAMESPACE"

if ! helm upgrade "$NAMESPACE" --namespace "$NAMESPACE" -f "$CUSTOM_VALUES" --set "ExtendApiKey=$APIKEY" "${TLS_OPTIONS[@]}" .; then
    echo "ERROR: helm upgrade failed."
    exit 1
fi

echo
echo "----------------------------------------------"
kubectl logs -l imaging.service=extendproxy --tail=-1 --namespace "$NAMESPACE" | grep "Admin Access url:" || true
echo "ExtendApiKey: $APIKEY"
echo "----------------------------------------------"

if [ -n "${BUNDLE_FILE_PATH:-}" ]; then
    echo "Getting EXTEND-PROXY-URL..."
    EXTEND_PROXY_URL="$(kubectl get deployment extendproxy -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="public_url")].value}')"
    echo "----------------------------------------------"
    echo "Uploading extend bundle:"
    echo "- File            : $BUNDLE_FILE_PATH"
    echo "- EXTEND-PROXY-URL: $EXTEND_PROXY_URL"
    echo "----------------------------------------------"
    curl -H "x-cxproxy-apikey:$APIKEY" -F "data=@${BUNDLE_FILE_PATH}" "${EXTEND_PROXY_URL}/api/synchronization/bundle/upload"
fi

# Cleanup
rm -f "$LOG_FILE"

echo "Done."