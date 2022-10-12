FROM postgres:14.5

RUN apt-get update && apt-get install wget sqlite3 -y

RUN wget -O /tmp/grafana-migrate https://github.com/wbh1/grafana-sqlite-to-postgres/releases/download/v2.1.0/grafana-migrate_linux_amd64-v2.1.0

RUN chmod +x /tmp/grafana-migrate