#!/bin/bash
# File: 02-verify-storage-class.sh
# Description: Creates and verifies the microk8s-hostpath storage class alias by testing actual storage operations
# Must be run in the container.

set -e

# Check if we're running in the container
if [ ! -d "/mnt/urbalurbadisk" ]; then
    echo "Error: This script must be run inside the provision-host container"
    echo "It should be executed via docker exec from the host"
    exit 1
fi

echo "Step 1: Creating storage class alias..."
# The storage class should already be applied by the calling script, but we'll check
if ! kubectl get storageclass microk8s-hostpath &> /dev/null; then
    echo "Storage class not found, applying it now..."
    kubectl apply -f /mnt/urbalurbadisk/manifests/000-storage-class-alias.yaml
fi

echo "Step 1b: Verifying storage class creation..."
if ! kubectl get storageclass microk8s-hostpath &> /dev/null; then
    echo "Failed to create storage class microk8s-hostpath"
    exit 1
fi

# Verify the provisioner is correct
PROVISIONER=$(kubectl get storageclass microk8s-hostpath -o jsonpath='{.provisioner}')
if [ "$PROVISIONER" != "rancher.io/local-path" ]; then
    echo "Storage class has incorrect provisioner: $PROVISIONER"
    exit 1
fi

echo "Storage class created and verified successfully"

echo "Step 2: Creating test PVC..."
kubectl apply -f /mnt/urbalurbadisk/manifests/001-storage-class-test-pvc.yaml

echo "Step 3: Creating test pod..."
kubectl apply -f /mnt/urbalurbadisk/manifests/002-storage-class-test-pod.yaml

echo "Step 4: Waiting for pod to be ready..."
kubectl wait --for=condition=ready pod/storage-test-pod --timeout=60s

echo "Step 5: Verifying file creation..."
if kubectl exec storage-test-pod -- cat /data/test.txt | grep "Storage test successful"; then
    echo "Storage test passed successfully!"
else
    echo "Storage test failed!"
    exit 1
fi

echo "Step 6: Cleaning up..."
kubectl delete pod storage-test-pod
kubectl delete pvc storage-test-pvc

echo "Storage class verification completed successfully!" 