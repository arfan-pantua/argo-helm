#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export DB_HOST=...
export DB_PORT=...
export DB_USER=...
export DB_PASS=...
export DB_NAME=...

export GF_NAMESPACE=grafana # or 'default'
export GF_RELEASE_NAME=grafana

# Set to the specific version
export GF_VERSION=6.17.9
#--------------------------------------------------------------------------------------

# Env Definition
export GF_PVC_MOUNT_DIR=/opt/gf-data
export GF_VALUES=grafana.values.yaml
export GF_POD_HELPER=gf-migrate-helper

export POD_MANIFEST="pod-helper.manifest.yaml"
export POD_CMD="pod-helper.install.sh"

# Set namespace
echo "-- Set the kubectl context to use the GF_NAMESPACE: $GF_NAMESPACE"
kubectl config set-context --current --namespace=$GF_NAMESPACE

# Scale the grafana to 0
echo "-- Scale Grafana's Deployment to 0"
kubectl scale deploy/grafana --replicas=0
sleep 5s

# Get the grafana PVC name
echo "-- Get the grafana PVC name"
export GF_PVC=$(kubectl get pvc -n $GF_NAMESPACE | awk '{print $1}' | grep grafana)
echo $GF_PVC


# Prepare the pod manifest
cat << EOF > $POD_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: $GF_POD_HELPER
  labels:
    app: $GF_POD_HELPER
spec:
  containers:
  - name: $GF_POD_HELPER
    image: postgres:latest
    command:
      - sleep
      - "8h"
    imagePullPolicy: IfNotPresent
  restartPolicy: Always
EOF
kubectl apply -f $POD_MANIFEST
echo "-- Waiting to available..."
kubectl wait pods -l app=$GF_POD_HELPER --for condition=Ready --timeout=90s

# Prepare the initial commands
cat << EOF > $POD_CMD
set -x
apt-get update && apt-get install -y \
  wget \
  sqlite3

export PGPASSWORD=$DB_PASS
psql --host=$DB_HOST --port=$DB_PORT -U $DB_USER --dbname=postgres -c 'drop database $DB_NAME'
psql --host=$DB_HOST --port=$DB_PORT -U $DB_USER --dbname=postgres -c 'create database $DB_NAME'

EOF
echo "-- Running the bootstrap script to create database..."
cat $POD_CMD
kubectl cp $POD_CMD $GF_POD_HELPER:/tmp/
kubectl exec po/$GF_POD_HELPER -- /bin/bash -c "chmod +x /tmp/$POD_CMD"
kubectl exec po/$GF_POD_HELPER -- /bin/bash -c "/tmp/$POD_CMD"
echo "-- Database is created!"
# Release helper pod
echo "-- Release the POD Helper"
kubectl delete -f $POD_MANIFEST

# Prepare the new values
helm get values grafana | tee $GF_VALUES
cp $GF_VALUES "$GF_VALUES.bak"
cat << EOF >> $GF_VALUES

env:
  GF_DATABASE_TYPE: postgres
  GF_DATABASE_HOST: $DB_HOST
  GF_DATABASE_NAME: $DB_NAME
  GF_DATABASE_USER: $DB_USER

envFromSecret: gf-database-password

EOF

echo "-- create secret grafana database password"
kubectl  create secret generic gf-database-password --from-literal=GF_DATABASE_PASSWORD=$DB_PASS

echo "-- Upgrade the helm: $GF_VERSION to create schema"
#helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --version $GF_VERSION grafana grafana/grafana --values $GF_VALUES

echo "-- Waiting to available..."
kubectl wait pods -l app.kubernetes.io/instance=$GF_RELEASE_NAME --for condition=Ready --timeout=3m

# Prepare the pod manifest
cat << EOF > $POD_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: $GF_POD_HELPER
  labels:
    app: $GF_POD_HELPER
spec:
  volumes:
    - name: pv-storage
      persistentVolumeClaim:
        claimName: $GF_PVC
  containers:
  - name: $GF_POD_HELPER
    image: postgres:latest
    command:
      - sleep
      - "8h"
    imagePullPolicy: IfNotPresent
    volumeMounts:
      - mountPath: "$GF_PVC_MOUNT_DIR"
        name: pv-storage
  restartPolicy: Always
EOF

echo "release pvc for used by Pod Helper"
kubectl scale deploy/grafana --replicas=0
sleep 5s

echo "-- Apply the pod manifest"
cat $POD_MANIFEST
kubectl apply -f $POD_MANIFEST

echo "-- Waiting to available..."
kubectl wait pods -l app=$GF_POD_HELPER --for condition=Ready --timeout=3m


# Prepare the initial commands
cat << EOF > $POD_CMD
set -x
apt-get update && apt-get install -y \
  wget \
  sqlite3

export PGPASSWORD=$DB_PASS
wget -O /tmp/grafana-migrate \
  https://github.com/wbh1/grafana-sqlite-to-postgres/releases/download/v2.1.0/grafana-migrate_linux_amd64-v2.1.0

chmod +x /tmp/grafana-migrate
/tmp/grafana-migrate \
  $GF_PVC_MOUNT_DIR/grafana.db \
  "postgres://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME?sslmode=disable"

EOF
echo "-- Running the bootstrap script..."
cat $POD_CMD
kubectl cp $POD_CMD $GF_POD_HELPER:/tmp/
kubectl exec po/$GF_POD_HELPER -- /bin/bash -c "chmod +x /tmp/$POD_CMD"
kubectl exec po/$GF_POD_HELPER -- /bin/bash -c "/tmp/$POD_CMD"

echo "-- Migration is complete!"
read -p "Press ENTER to continue, or Ctrl+C to stop..." tmp


# Release helper pod
echo "-- Release the POD Helper"
kubectl delete -f $POD_MANIFEST
# Scaling grafana
echo "release pvc for used by Pod Helper"
kubectl scale deploy/grafana --replicas=1
sleep 5s
rm $POD_CMD $GF_VALUES *.bak