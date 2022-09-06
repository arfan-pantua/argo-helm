#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export SERVICE_ACCOUNT_NAME="<SERVICE_ACCOUNT_NAME>"
export BUCKET_NAME="<BUCKET_NAME>"

export PROM_NAMESPACE=prometheus # or 'default'
export PROM_RELEASE_NAME=prometheus
export PROM_JOB_SIDE=job.rollback.yaml
export PROM_JOB_NAME=job-rollback-helper

# Set to the specific version
export PROM_VERSION=15.0.4
#-------------------------------------------------------------------------------------
# Env Definition
export PROM_VALUES=prometheus.values.yaml
export PROM_POD_HELPER=prom-migrate-helper
export POD_MANIFEST="pod-helper.manifest.yaml"
export PROM_PVC="prometheus-server"


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
kubectl delete statefulset/prometheus-server
#kubectl delete deployments.apps -l relese=prometheus,component=server
kubectl wait pods -l release=$PROM_RELEASE_NAME,component=server --for=delete --timeout=300s
sleep 50s
helm upgrade --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES.bak
kubectl wait pods -l release=$PROM_RELEASE_NAME,component=server --for condition=Ready --timeout=300s
echo "-- uninstall thanos"
helm uninstall thanos
sleep 15s


cat << EOF > $PROM_JOB_SIDE
apiVersion: batch/v1
kind: Job
metadata:
  name: $PROM_JOB_NAME
spec:
  template:
    spec:
      volumes:
        - name: job-migration-storage
          persistentVolumeClaim:
            claimName: $PROM_PVC
      serviceAccountName: $SERVICE_ACCOUNT_NAME
      affinity:
        # The Pod affinity rule tells the scheduler to place each replica on a node that has a Pod with the label app=prometheus
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - prometheus
            topologyKey: "kubernetes.io/hostname"
      containers:
      - name: job-migration
        image: 706050889978.dkr.ecr.ap-southeast-1.amazonaws.com/devops-monitoring-stack-upgrade:prometheus
        imagePullPolicy: Always
        command: ["/bin/sh"]
        args: ["-c", "cd /home; aws s3 cp s3://$BUCKET_NAME /tmp/data --recursive;"]
        volumeMounts:
        - mountPath: /tmp/data
          name: job-migration-storage
        resources:
          limits:
            cpu: 0.25
            memory: 250Mi
          requests:
            cpu: 0.20
            memory: 250Mi
      restartPolicy: Never
  backoffLimit: 4
EOF

echo "... apply the job ..."
kubectl apply -f $PROM_JOB_SIDE
kubectl wait --for=condition=complete --timeout=20m job/$PROM_JOB_NAME
sleep 5s

# Delete job
kubectl delete jobs $PROM_JOB_NAME
echo "-- Data is copied to local!"
kubectl delete serviceaccount $SERVICE_ACCOUNT_NAME

