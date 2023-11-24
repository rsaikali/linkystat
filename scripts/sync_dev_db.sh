#!/bin/bash -e

production_host=linky.local

# Backup production MySQL database
ssh ${production_host} /bin/bash <<EOF
    mysql_docker_id=\$(docker ps -f name=mysql --format "{{.ID}}")
    mysql_root_password=\$(docker exec \${mysql_docker_id} printenv MYSQL_ROOT_PASSWORD)
    mysql_database=\$(docker exec \${mysql_docker_id} printenv MYSQL_DATABASE)
    docker exec \${mysql_docker_id} /usr/bin/mysqldump -u root --password='\${mysql_root_password}' --insert-ignore --skip-triggers --compact --no-create-db --no-create-info -B \${mysql_database} | gzip -c > /tmp/backup.sql.gz
EOF

# Copy new SQL dump file locally
scp ${production_host}:/tmp/backup.sql.gz .

# Restore local MySQL database
mysql_docker_id=$(docker ps -f name=mysql --format "{{.ID}}")
mysql_root_password=$(docker exec ${mysql_docker_id} printenv MYSQL_ROOT_PASSWORD)
mysql_database=$(docker exec ${mysql_docker_id} printenv MYSQL_DATABASE)
zcat backup.sql.gz | docker exec -i ${mysql_docker_id} /usr/bin/mysql -u root --password='${mysql_root_password}' ${mysql_database}

# Remove SQL dump file
rm -Rf backup.sql.gz
