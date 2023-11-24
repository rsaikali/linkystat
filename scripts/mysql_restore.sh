#!/bin/bash -e

# Get backup filename as parameter
backup_file=$1

# Get MySQL docker ID and MySQL password
mysql_docker_id=$(docker ps -f name=mysql --format "{{.ID}}")
mysql_root_password=$(docker exec ${mysql_docker_id} printenv MYSQL_ROOT_PASSWORD)
mysql_database=$(docker exec ${mysql_docker_id} printenv MYSQL_DATABASE)

# Load backup file into MySQL database
zcat ${backup_file} | docker exec -i ${mysql_docker_id} /usr/bin/mysql -u root --password=${mysql_root_password} ${mysql_database}
