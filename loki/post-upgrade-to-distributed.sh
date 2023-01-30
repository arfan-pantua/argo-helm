#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
# Grafana
export CURRENT_GF_DATA_SOURCE=...#http://loki.loki.svc:3100
export NEXT_GF_DATA_SOURCE=...   #http://loki-loki-distributed-querier.loki:3100

export GF_NAMESPACE=grafana # or 'default'

# Set to the specific version
export GF_VERSION=6.30.3
export APP_VERSION=8.5.15

# Promtail
export PROMTAIL_NAMESPACE=... # or 'default'
export PROMTAIL_RELEASE_NAME=...
export LOKI_NAMESPACE=...

# Set to the specific version
export PROMTAIL_VERSION=3.0.0
#--------------------------------------------------------------------------------------
#!!! Just ignore when grafana doesnt need to run in dedicated Node, but fill the values if the pod need to run in dedicated node !!!
export DEDICATED_NODE=false
export effect=.""
export key=""
export value=""
export operator=""
export label_node_key=""
export label_node_value=""


# Env Definition
export GF_VALUES=grafana.values.yaml
export PROMTAIL_VALUES=promtail.values.yaml

# Set namespace
echo "-- Set the kubectl context to use: $GF_NAMESPACE"
kubectl config set-context --current --namespace=$GF_NAMESPACE


# Scale the grafana to 0
echo "-- Scale Grafana's Deployment to 0"
kubectl scale deploy/grafana --replicas=0
sleep 10s

# Prepare the new values
helm get values grafana | tee $GF_VALUES
cp $GF_VALUES "$GF_VALUES.bak"
sed -i  "s|$CURRENT_GF_DATA_SOURCE *|$NEXT_GF_DATA_SOURCE |" $GF_VALUES


if [[ $DEDICATED_NODE = true ]]
then
    helm upgrade --version $GF_VERSION grafana grafana/grafana --values $GF_VALUES --set replicas=3 \
    --set tolerations[0].operator=$operator,tolerations[0].effect=$effect,tolerations[0].key=$key,tolerations[0].value=$value \
    --set nodeSelector.$label_node_key=$label_node_value \
    --set image.repository=grafana/grafana --set image.tag=$APP_VERSION
else
    helm upgrade --version $GF_VERSION grafana grafana/grafana --values $GF_VALUES --set replicas=3 \
    --set image.repository=grafana/grafana --set image.tag=$APP_VERSION
fi

# Update promtail

# Set namespace
echo "-- Set the kubectl context to use: $PROMTAIL_NAMESPACE"
kubectl config set-context --current --namespace=$PROMTAIL_NAMESPACE

helm get values promtail | tee $PROMTAIL_VALUES
cp $PROMTAIL_VALUES "$PROMTAIL_VALUES.bak"
cat << EOF > $PROMTAIL_VALUES
loki:
  serviceName: loki-loki-distributed-gateway.$LOKI_NAMESPACE
  servicePort: 80
config:
  client:
    # Maximum wait period before sending batch
    batchwait: 5s
    backoff_config:
      # Initial backoff time between retries
      min_period: 100ms
      # Maximum backoff time between retries
      max_period: 5m
      # Maximum number of retries when sending batches, 0 means infinite retries
      max_retries: 20
# resources:
#  limits:
#    cpu: 0.2
#    memory: 500Mi
EOF

kubectl delete daemonset promtail
helm repo add promtail https://grafana.github.io/helm-charts
helm repo update
if [[ $DEDICATED_NODE = true ]]
then
    helm upgrade --version $PROMTAIL_VERSION promtail promtail/promtail --values $PROMTAIL_VALUES \
    --set tolerations[0].operator=$operator,tolerations[0].effect=$effect,tolerations[0].key=$key,tolerations[0].value=$value
else
    helm upgrade --version $PROMTAIL_VERSION promtail promtail/promtail --values $PROMTAIL_VALUES
fi
