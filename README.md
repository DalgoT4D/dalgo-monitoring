## Dalgo monitoring

We have a separate monitoring instance (in `everything` machine) that talks to various sources and collects metrics. There are two primary data stores involved in this monitoring setup

### Prometheus

Prometheus is an open-source monitoring and alerting toolkit designed to monitor and gather data from various sources within your infrastructure, providing insights into the health and performance of your systems. Prometheus collects time-series data by periodically polling configured targets using HTTP or other protocols.

In Dalgo's setup, we are monitoring the following data sources
- Dalgo's production ec2 machine (hardware & OS metrics)
- Dalgo's airbyte postgres RDS (postgres sever metrics)
- Django app metrics that are readily available via `django-prometheus` package. 

Prometheus's database is a local timeseries database, situated at `/var/lib/prometheus`. 

To visaulize and gather data from various sources we use `Grafana`

### Loki

Loki is an open-source, horizontally-scalable log aggregation system designed to efficiently store and query massive amounts of log data. Unlike traditional log aggregation tools, Loki doesn't store logs as individual documents but rather in chunks, which significantly reduces storage costs and improves query performance.

## Data sources

### Ec2 instance metrics

[Node exporter](https://github.com/prometheus/node_exporter) is the prometheus exporter for hardware & OS metrics.

The node exporter is installed in the host machine that needs to be monitored. As the name suggests, it will compute & export OS level metrics. 

Metrics can be scraped from this by adding this data source as a target in `prometheus.yml`.


### Postgres server metrics

[Postgres exporter](https://github.com/prometheus-community/postgres_exporter) is the prometheus exporter for postgres server metrics

The postgres exporter is run as a service on the monitoring machine and configured/connected to the remote RDS that needs to be monitored. 

The configuration is in the `.env` file present at `/etc/postgres_exporter/postgres_exporter.env`

The best practice here is to create a monitoring rds user and give the minimal permissions to monitor. 

Metrics can be scraped by adding this as a target in `prometheus.yml`

### Django app monitoring metrics

[django-prometheus](https://pypi.org/project/django-prometheus/1.0.11/) package computes the metrics and exposes an http endpoint for prometheus to scrape from. All the setup instructions are [here](https://pypi.org/project/django-prometheus/). Works very easily and outside the box. 

This again is installed on the host machine where the Dalgo django app is running.


### Logs via promtail

[Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/) is the agent responsible for packaging and sending local logs to Grafana's Loki instance. 

Promtail is supposed to be installed in the host machine where the logs are situated assuming we want to route logs in file system to Loki. 

The Loki instance will be present in the monitoring server. Http protocols are used to push logs from remote host (Dalgo prod) machine to Loki instance on the monitoring server. 


## Visualizing with grafana

[Grafana](https://github.com/grafana/grafana) is the open-source platform for monitoring and observability. You can create dynamic dashboards in grafana with `prometheus` and `loki` as your data sources. You can also explore logs and setup alerting

In the current, Dalgo monitoring setup - grafana uses a local sqlite db. 

We have 4 alerts setup in grafana
1. Based on the logs processed by loki.
2. Based on the RAM (node metrics) increasing a threshold.
3. Based on the disk space (node metrics) running low. 
4. Based on the no of connections to RDS (postgres server metrics).
