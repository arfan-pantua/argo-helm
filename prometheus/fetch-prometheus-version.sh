kubectl config set-context --current --namespace=prometheus
helm list | grep prometheus | awk '{print "PROM_CHART_VERSION="$9}' >> prometheus.version.bak
helm list | grep prometheus | awk '{print "PROM_APP_VERSION="$10}' >> prometheus.version.bak