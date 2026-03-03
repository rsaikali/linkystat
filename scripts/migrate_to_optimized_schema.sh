#!/bin/bash
#
# migrate_to_optimized_schema.sh
# 
# Migrates existing linky_history data to optimized aggregated tables.
# This script should be run ONCE after applying the new schema.
#
# Usage: ./scripts/migrate_to_optimized_schema.sh [jour_releve_compteur]
#
# Arguments:
#   jour_releve_compteur: Day of month for meter reading (default: 24)

set -e

JOUR_RELEVE="${1:-24}"

echo "========================================="
echo "   LinkyStats Schema Migration Tool"
echo "========================================="
echo ""
echo "Meter reading day: ${JOUR_RELEVE}"
echo ""

# Source environment variables
if [ -f .env ]; then
    echo "[INFO] Loading environment from .env file..."
    export $(grep -v '^#' .env | xargs)
else
    echo "[ERROR] .env file not found!"
    exit 1
fi

MYSQL_CONTAINER="${MYSQL_CONTAINER:-linky2db-mysql-1}"

# Check if MySQL container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER}$"; then
    echo "[ERROR] MySQL container '${MYSQL_CONTAINER}' is not running!"
    echo "[INFO] Start it with: docker compose up -d mysql"
    exit 1
fi

echo "[INFO] Connected to MySQL container: ${MYSQL_CONTAINER}"
echo ""

# Function to run MySQL command
run_mysql() {
    docker exec -i ${MYSQL_CONTAINER} mysql \
        -u root \
        -p${MYSQL_ROOT_PASSWORD} \
        ${MYSQL_DATABASE} \
        -e "$1"
}

# Get data range
echo "[STEP 1/5] Analyzing existing data..."
DATA_RANGE=$(run_mysql "
    SELECT 
        DATE(MIN(time)) as min_date,
        DATE(MAX(time)) as max_date,
        COUNT(*) as total_rows,
        DATEDIFF(MAX(time), MIN(time)) as days_span
    FROM linky_history;
")

echo "$DATA_RANGE"
echo ""

MIN_DATE=$(echo "$DATA_RANGE" | tail -n 1 | awk '{print $1}')
MAX_DATE=$(echo "$DATA_RANGE" | tail -n 1 | awk '{print $2}')
TOTAL_ROWS=$(echo "$DATA_RANGE" | tail -n 1 | awk '{print $3}')
DAYS_SPAN=$(echo "$DATA_RANGE" | tail -n 1 | awk '{print $4}')

if [ -z "$MIN_DATE" ] || [ "$MIN_DATE" == "NULL" ]; then
    echo "[ERROR] No data found in linky_history table!"
    exit 1
fi

echo "[INFO] Data range: ${MIN_DATE} to ${MAX_DATE}"
echo "[INFO] Total rows: ${TOTAL_ROWS} (${DAYS_SPAN} days)"
echo ""

# Populate daily aggregates
echo "[STEP 2/5] Populating daily aggregates..."
echo "[INFO] This may take several minutes for ${DAYS_SPAN} days..."

run_mysql "
    INSERT INTO linky_daily (
        date, 
        hchp_start, hchp_end, 
        hchc_start, hchc_end,
        hchp_kwh, hchc_kwh, total_kwh,
        avg_temp, min_temp, max_temp,
        data_points
    )
    SELECT 
        DATE(time) as date,
        MIN(HCHP) as hchp_start,
        MAX(HCHP) as hchp_end,
        MIN(HCHC) as hchc_start,
        MAX(HCHC) as hchc_end,
        (MAX(HCHP) - MIN(HCHP)) / 1000 as hchp_kwh,
        (MAX(HCHC) - MIN(HCHC)) / 1000 as hchc_kwh,
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 as total_kwh,
        ROUND(AVG(temperature), 2) as avg_temp,
        ROUND(MIN(temperature), 2) as min_temp,
        ROUND(MAX(temperature), 2) as max_temp,
        COUNT(*) as data_points
    FROM linky_history
    GROUP BY DATE(time)
    ORDER BY DATE(time)
    ON DUPLICATE KEY UPDATE
        hchp_start = VALUES(hchp_start),
        hchp_end = VALUES(hchp_end),
        hchc_start = VALUES(hchc_start),
        hchc_end = VALUES(hchc_end),
        hchp_kwh = VALUES(hchp_kwh),
        hchc_kwh = VALUES(hchc_kwh),
        total_kwh = VALUES(total_kwh),
        avg_temp = VALUES(avg_temp),
        min_temp = VALUES(min_temp),
        max_temp = VALUES(max_temp),
        data_points = VALUES(data_points);
"

DAILY_COUNT=$(run_mysql "SELECT COUNT(*) FROM linky_daily;" | tail -n 1)
echo "[SUCCESS] Created ${DAILY_COUNT} daily aggregates"
echo ""

# Populate monthly aggregates
echo "[STEP 3/5] Populating monthly aggregates..."
echo "[INFO] Using billing day: ${JOUR_RELEVE}"

# Create temporary table with billing periods
run_mysql "
    DROP TEMPORARY TABLE IF EXISTS billing_periods;
    
    CREATE TEMPORARY TABLE billing_periods AS
    SELECT DISTINCT
        DATE_FORMAT(
            DATE_ADD(
                DATE(time),
                INTERVAL (${JOUR_RELEVE} - DAY(time)) DAY
            ),
            '%Y-%m-${JOUR_RELEVE}'
        ) as billing_month
    FROM linky_history
    WHERE DAY(time) = ${JOUR_RELEVE} AND HOUR(time) = 0
    ORDER BY billing_month;
"

# Get billing periods and populate monthly aggregates
echo "[INFO] Generating monthly aggregates for each billing period..."

BILLING_PERIODS=$(run_mysql "SELECT billing_month FROM billing_periods;" | tail -n +2)

if [ -z "$BILLING_PERIODS" ]; then
    echo "[WARNING] No billing periods found! Make sure data exists for day ${JOUR_RELEVE}"
else
    PERIOD_COUNT=0
    TOTAL_PERIODS=$(echo "$BILLING_PERIODS" | wc -l)
    
    while IFS= read -r billing_month; do
        PERIOD_COUNT=$((PERIOD_COUNT + 1))
        echo -ne "[INFO] Processing period ${PERIOD_COUNT}/${TOTAL_PERIODS}: ${billing_month}...\r"
        
        # Call the stored procedure for this billing period
        docker exec -i ${MYSQL_CONTAINER} mysql \
            -u root \
            -p${MYSQL_ROOT_PASSWORD} \
            ${MYSQL_DATABASE} \
            -e "CALL refresh_monthly_aggregate('${billing_month}', ${JOUR_RELEVE});" 2>/dev/null || true
    done <<< "$BILLING_PERIODS"
    
    echo ""
    MONTHLY_COUNT=$(run_mysql "SELECT COUNT(*) FROM linky_monthly;" | tail -n 1)
    echo "[SUCCESS] Created ${MONTHLY_COUNT} monthly aggregates"
fi

echo ""

# Verify data integrity
echo "[STEP 4/5] Verifying data integrity..."

VERIFICATION=$(run_mysql "
    SELECT 
        'Daily' as table_name,
        COUNT(*) as rows,
        MIN(date) as min_date,
        MAX(date) as max_date
    FROM linky_daily
    UNION ALL
    SELECT 
        'Monthly' as table_name,
        COUNT(*) as rows,
        MIN(billing_month) as min_date,
        MAX(billing_month) as max_date
    FROM linky_monthly;
")

echo "$VERIFICATION"
echo ""

# Show sample data
echo "[STEP 5/5] Sample aggregated data:"
echo ""
echo "--- Latest daily data ---"
run_mysql "
    SELECT 
        date,
        CONCAT(ROUND(total_kwh, 2), ' kWh') as consumption,
        CONCAT(ROUND(avg_temp, 1), '°C') as temp,
        data_points
    FROM linky_daily
    ORDER BY date DESC
    LIMIT 5;
"

echo ""
echo "--- Latest monthly data ---"
run_mysql "
    SELECT 
        billing_month,
        CONCAT(ROUND(total_kwh, 2), ' kWh') as consumption,
        CONCAT(ROUND(avg_temp, 1), '°C') as temp,
        nb_days as days
    FROM linky_monthly
    ORDER BY billing_month DESC
    LIMIT 5;
"

echo ""
echo "========================================="
echo "   Migration completed successfully!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Update Grafana dashboards to use optimized tables"
echo "2. Monitor MySQL Events are running:"
echo "   docker exec ${MYSQL_CONTAINER} mysql -u root -p${MYSQL_ROOT_PASSWORD} -e 'SHOW EVENTS FROM ${MYSQL_DATABASE};'"
echo "3. Check daily/hourly aggregations are updating automatically"
echo ""
