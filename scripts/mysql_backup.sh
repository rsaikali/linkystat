#!/bin/bash -e

backup_directory=~/linkystat_backups

# Create backup directory
mkdir -p ${backup_directory}

# Define backup filename (timestamped)
current_date=$(date '+%Y-%m-%d')
backup_file="${backup_directory}/mysql_backup_linkystat_${current_date}.sql.gz"

# Get MySQL password and database
mysql_docker_id=$(docker ps -f name=mysql --format "{{.ID}}")
mysql_root_password=$(docker exec ${mysql_docker_id} printenv MYSQL_ROOT_PASSWORD)
mysql_database=$(docker exec ${mysql_docker_id} printenv MYSQL_DATABASE)

# Get Grafana administrator email address
grafana_docker_id=$(docker ps -f name=grafana --format "{{.ID}}")
grafana_admin_email=$(docker exec ${grafana_docker_id} printenv GF_SECURITY_ADMIN_EMAIL)

# MySQL dump database to timestamped backup file
docker exec ${mysql_docker_id} /usr/bin/mysqldump -u root --password=${mysql_root_password} --insert-ignore --skip-triggers --compact --no-create-db --no-create-info -B ${mysql_database} | gzip -c > ${backup_file}

# Send mail with timestamped backup file attached
backup_size=$(du -sk ${backup_file} | cut -f1)
echo "LinkyStat MySQL backup size on ${current_date} is ${backup_size}ko" | mail -s "LinkyStat MySQL backup ${current_date} [${backup_size}ko]" ${grafana_admin_email} -A ${backup_file}

# Keep only 3 latest backup files
cd ${backup_directory}
rm `ls -t ${backup_directory} | awk 'NR>3'` || true
