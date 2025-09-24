#!/bin/bash

# Script to remove resource limits from all deployments and statefulsets
# This is useful when you have insufficient cluster resources

echo "Removing resource limits from all deployments and statefulsets..."

# Get all namespaces
NAMESPACES=$(kubectl get namespaces -o name | cut -d'/' -f2)

for ns in $NAMESPACES; do
    echo "Processing namespace: $ns"
    
    # Process deployments
    DEPLOYMENTS=$(kubectl get deployments -n $ns -o name 2>/dev/null | cut -d'/' -f2)
    for deploy in $DEPLOYMENTS; do
        echo "  Checking deployment: $deploy"
        # Check if deployment has resources defined
        if kubectl get deployment -n $ns $deploy -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null | grep -q "limits\|requests"; then
            echo "    Removing resources from deployment: $deploy"
            kubectl patch deployment -n $ns $deploy --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/resources"}]' 2>/dev/null || echo "    Failed to patch $deploy"
        fi
    done
    
    # Process statefulsets
    STATEFULSETS=$(kubectl get statefulsets -n $ns -o name 2>/dev/null | cut -d'/' -f2)
    for sts in $STATEFULSETS; do
        echo "  Checking statefulset: $sts"
        # Check if statefulset has resources defined
        if kubectl get statefulset -n $ns $sts -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null | grep -q "limits\|requests"; then
            echo "    Removing resources from statefulset: $sts"
            kubectl patch statefulset -n $ns $sts --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/resources"}]' 2>/dev/null || echo "    Failed to patch $sts"
        fi
    done
done

echo "Done! Check pod status with: kubectl get pods -A"
