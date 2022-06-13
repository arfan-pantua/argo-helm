helm list | grep grafana | awk '{print "GF_CHART_VERSION="$9}' >> grafana.version.bak
helm list | grep grafana | awk '{print "GF_APP_VERSION="$10}' >> grafana.version.bak