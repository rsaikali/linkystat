#!/bin/bash -e

echo "Starting database sync from production to local..."

# Backup production MySQL database
echo "Backing up production database..."
ssh $PRODUCTION_USER@$PRODUCTION_DB_HOST /bin/bash <<EOF
    mysql_docker_id=\$(docker ps -f name=mysql --format "{{.ID}}")
    mysql_root_password=\$(docker exec \${mysql_docker_id} printenv MYSQL_ROOT_PASSWORD)
    mysql_database=\$(docker exec \${mysql_docker_id} printenv MYSQL_DATABASE)
    docker exec \${mysql_docker_id} /usr/bin/mysqldump -u root --password=\${mysql_root_password} --insert-ignore --skip-triggers --compact --no-create-db --no-create-info -B \${mysql_database} | gzip -c > /tmp/backup.sql.gz
EOF

# Copy new SQL dump file locally
echo "Copying backup file locally..."
scp $PRODUCTION_USER@$PRODUCTION_DB_HOST:/tmp/backup.sql.gz .

# Restore local MySQL database
mysql_docker_id=$(docker ps -f name=mysql --format "{{.ID}}")
echo "Restoring database in docker container $mysql_docker_id"
zcat backup.sql.gz | docker exec -i ${mysql_docker_id} /usr/bin/mysql -u root --password=$MYSQL_ROOT_PASSWORD $MYSQL_DATABASE

# Remove SQL dump file
echo "Cleaning up..."
rm -Rf backup.sql.gz


