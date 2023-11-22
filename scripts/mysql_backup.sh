#!/bin/bash -e

# Get MySQL password and database
mysql_docker_id=$(docker ps -f name=mysql --format "{{.ID}}")
mysql_root_password=$(docker exec ${mysql_docker_id} printenv MYSQL_ROOT_PASSWORD)
mysql_database=$(docker exec ${mysql_docker_id} printenv MYSQL_DATABASE)

# Get Grafana administrator email address
grafana_docker_id=$(docker ps -f name=grafana --format "{{.ID}}")
grafana_admin_email=$(docker exec ${grafana_docker_id} printenv GF_SECURITY_ADMIN_EMAIL)

# MySQL dump database to timestamped backup file
docker exec ${mysql_docker_id} /usr/bin/mysqldump -u root --password=${mysql_root_password} --insert-ignore --skip-triggers --compact --no-create-db --no-create-info -B ${mysql_database} | gzip -c > ./linkystat_mysql_backup.sql.gz
