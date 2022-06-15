#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export PROM_NAMESPACE=prometheus # or 'default'
export PROM_RELEASE_NAME=prometheus

# Set to the specific version
export PROM_VERSION=13.0.0

# Env Definition
export PROM_VALUES=prom.values.yaml
export PROM_POD_HELPER=prom-migrate-helper
export POD_MANIFEST="pod-helper.manifest.yaml"
export SERVICE_ACCOUNT_NAME="<SERVICE_ACCOUNT_NAME>"
export PROM_PVC="prometheus-server"
export BUCKET_NAME="<BUCKET_NAME>"

# Set namespace
echo "-- Set the kubectl context to use the PROM_NAMESPACE: $PROM_NAMESPACE"
kubectl config set-context --current --namespace=$PROM_NAMESPACE

# Scale the prometheus to 0
echo "-- Scale Prometheus's Statefullset to 0"
kubectl scale statefulset/prometheus-server --replicas=0
kubectl scale deploy/prometheus-alertmanager --replicas=0

echo "-- Upgrade the helm: $PROM_VERSION"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update
kubectl delete deployments.apps -l app.kubernetes.io/instance=prometheus,app.kubernetes.io/name=kube-state-metrics --cascade=orphan
helm upgrade --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES.bak

echo "-- uninstall thanos"
helm uninstall thanos
sleep 15s

# Prepare the pod manifest
cat << EOF > $POD_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: $PROM_POD_HELPER
  labels:
    app: $PROM_POD_HELPER
spec:
  serviceAccountName: $SERVICE_ACCOUNT_NAME
  volumes:
    - name: pv-storage
      persistentVolumeClaim:
        claimName: $PROM_PVC
  containers:
  - name: $PROM_POD_HELPER
    image: arfanpantua/monitoring-installer:1.0
    imagePullPolicy: IfNotPresent
    command: ["/bin/sh"]
    args: ["-c", "while true;do cd /home; curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip;unzip awscliv2.zip; ./aws/install; sleep 24h;done"] 
    volumeMounts:
      - mountPath: "/tmp/data"
        name: pv-storage
  restartPolicy: Always
EOF

echo "-- Scale Prometheus's Statefullset to 0"
kubectl scale deploy/prometheus-server --replicas=0
sleep 5s
kubectl apply -f $POD_MANIFEST
echo "-- Waiting to available..."
kubectl wait pods -l app=$PROM_POD_HELPER --for condition=Ready --timeout=100s
sleep 30s
echo "-- Migration data to local..."
kubectl exec po/$PROM_POD_HELPER -- /bin/bash -c "aws s3 cp s3://$BUCKET_NAME /tmp/data  --recursive"
echo "-- Data is copied to local!"

# Release helper pod
echo "-- Release the POD Helper"
kubectl delete -f $POD_MANIFEST

echo "-- Scale Prometheus's Statefullset to 0"
kubectl scale deploy/prometheus-server --replicas=1
