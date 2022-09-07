#!/bin/bash

set -e -x
export GF_NAMESPACE=...
kubectl config set-context --current --namespace=$GF_NAMESPACE
helm list | grep grafana | awk '{print "GF_CHART_VERSION="$9}' >> grafana.version.bak
helm list | grep grafana | awk '{print "GF_APP_VERSION="$10}' >> grafana.version.bak