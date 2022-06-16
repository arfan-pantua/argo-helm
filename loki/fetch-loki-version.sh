helm list | grep loki | awk '{print "LOKI_CHART_VERSION="$9}' >> loki.version.bak
helm list | grep loki | awk '{print "LOKI_APP_VERSION="$10}' >> loki.version.bak