#!/bin/sh -xe

unset MYSQL_HOST
unset MYSQL_PORT

echo "*********************************"
echo "*** Creating Linkystat schema ***"
echo "*********************************"

echo "********** Creating ${GRAFANA_MYSQL_USER} user **********"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
CREATE USER IF NOT EXISTS '${GRAFANA_MYSQL_USER}' IDENTIFIED BY '${GRAFANA_MYSQL_PASSWORD}';
GRANT SELECT, SHOW VIEW, EXECUTE ON ${MYSQL_DATABASE}.* TO '${GRAFANA_MYSQL_USER}';
FLUSH PRIVILEGES;
"

echo "************* Creating base tables with indexes *************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
CREATE TABLE IF NOT EXISTS linky_realtime (
    time DATETIME NOT NULL,
    PAPP SMALLINT UNSIGNED NOT NULL,
    HCHP INTEGER UNSIGNED NOT NULL,
    HCHC INTEGER UNSIGNED NOT NULL,
    temperature DOUBLE,
    libelle_tarif VARCHAR(16),
    PRIMARY KEY (time),
    INDEX idx_realtime_time (time)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS linky_history (
    time DATETIME NOT NULL,
    HCHC INTEGER UNSIGNED DEFAULT 0,
    HCHP INTEGER UNSIGNED DEFAULT 0,
    temperature DOUBLE,
    PRIMARY KEY (time),
    INDEX idx_history_time (time),
    INDEX idx_history_day_hour (DAY(time), HOUR(time))
) ENGINE=InnoDB;
"

echo "************* Creating aggregated tables *************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
-- Daily aggregation table (stores daily consumption from midnight to midnight)
CREATE TABLE IF NOT EXISTS linky_daily (
    date DATE NOT NULL,
    hchp_start INTEGER UNSIGNED NOT NULL COMMENT 'HCHP counter value at start of day',
    hchp_end INTEGER UNSIGNED NOT NULL COMMENT 'HCHP counter value at end of day',
    hchc_start INTEGER UNSIGNED NOT NULL COMMENT 'HCHC counter value at start of day',
    hchc_end INTEGER UNSIGNED NOT NULL COMMENT 'HCHC counter value at end of day',
    hchp_kwh DECIMAL(10,3) NOT NULL COMMENT 'HCHP consumption in kWh for the day',
    hchc_kwh DECIMAL(10,3) NOT NULL COMMENT 'HCHC consumption in kWh for the day',
    total_kwh DECIMAL(10,3) NOT NULL COMMENT 'Total consumption in kWh for the day',
    avg_temp DECIMAL(5,2) COMMENT 'Average temperature for the day',
    min_temp DECIMAL(5,2) COMMENT 'Minimum temperature for the day',
    max_temp DECIMAL(5,2) COMMENT 'Maximum temperature for the day',
    data_points INTEGER UNSIGNED COMMENT 'Number of hourly data points',
    PRIMARY KEY (date),
    INDEX idx_daily_date (date)
) ENGINE=InnoDB;

-- Monthly aggregation table (stores consumption between meter reading dates)
-- The 'billing_month' is the DATE of the meter reading (e.g., 2024-01-24 for reading on Jan 24)
CREATE TABLE IF NOT EXISTS linky_monthly (
    billing_month DATE NOT NULL COMMENT 'Date of meter reading (format: YYYY-MM-DD where DD is jour_releve_compteur)',
    year_val SMALLINT UNSIGNED NOT NULL,
    month_val TINYINT UNSIGNED NOT NULL,
    reading_day TINYINT UNSIGNED NOT NULL COMMENT 'Day of month for meter reading (jour_releve_compteur)',
    hchp_start INTEGER UNSIGNED NOT NULL COMMENT 'HCHP counter at start of billing period',
    hchp_end INTEGER UNSIGNED NOT NULL COMMENT 'HCHP counter at end of billing period',
    hchc_start INTEGER UNSIGNED NOT NULL COMMENT 'HCHC counter at start of billing period',
    hchc_end INTEGER UNSIGNED NOT NULL COMMENT 'HCHC counter at end of billing period',
    hchp_kwh DECIMAL(10,3) NOT NULL COMMENT 'HCHP consumption in kWh for the billing period',
    hchc_kwh DECIMAL(10,3) NOT NULL COMMENT 'HCHC consumption in kWh for the billing period',
    total_kwh DECIMAL(10,3) NOT NULL COMMENT 'Total consumption in kWh for the billing period',
    avg_temp DECIMAL(5,2) COMMENT 'Average temperature for the billing period',
    min_temp DECIMAL(5,2) COMMENT 'Minimum temperature for the billing period',
    max_temp DECIMAL(5,2) COMMENT 'Maximum temperature for the billing period',
    nb_days INTEGER UNSIGNED COMMENT 'Number of days in the billing period',
    data_points INTEGER UNSIGNED COMMENT 'Number of data points in the period',
    PRIMARY KEY (billing_month),
    INDEX idx_monthly_year_month (year_val, month_val),
    INDEX idx_monthly_reading_day (reading_day)
) ENGINE=InnoDB;
"

echo "************ Creating triggers ************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
DELIMITER ;;
CREATE TRIGGER IF NOT EXISTS realtime_trigger AFTER INSERT ON linky_realtime FOR EACH ROW
BEGIN
    INSERT INTO linky_history (time, HCHC, HCHP, temperature)
    VALUES(
        STR_TO_DATE(DATE_FORMAT(DATE_ADD(NOW(), INTERVAL 1 HOUR), '%Y-%m-%d %H:00:00'), '%Y-%m-%d %T'),
        NEW.HCHC,
        NEW.HCHP,
        NEW.temperature
    )
    ON DUPLICATE KEY UPDATE 
        HCHC = NEW.HCHC, 
        HCHP = NEW.HCHP, 
        temperature = NEW.temperature;
END;;
DELIMITER ;
"

echo "************* Creating stored procedures *************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
DELIMITER ;;

-- Procedure to refresh daily aggregations for a specific date
CREATE PROCEDURE IF NOT EXISTS refresh_daily_aggregate(IN target_date DATE)
BEGIN
    DECLARE v_hchp_start INTEGER;
    DECLARE v_hchp_end INTEGER;
    DECLARE v_hchc_start INTEGER;
    DECLARE v_hchc_end INTEGER;
    DECLARE v_avg_temp DECIMAL(5,2);
    DECLARE v_min_temp DECIMAL(5,2);
    DECLARE v_max_temp DECIMAL(5,2);
    DECLARE v_data_points INTEGER;
    
    -- Get aggregated data for the day
    SELECT 
        MIN(HCHP),
        MAX(HCHP),
        MIN(HCHC),
        MAX(HCHC),
        ROUND(AVG(temperature), 2),
        ROUND(MIN(temperature), 2),
        ROUND(MAX(temperature), 2),
        COUNT(*)
    INTO 
        v_hchp_start, v_hchp_end, v_hchc_start, v_hchc_end,
        v_avg_temp, v_min_temp, v_max_temp, v_data_points
    FROM linky_history
    WHERE DATE(time) = target_date;
    
    -- Insert or update the daily aggregate
    IF v_hchp_start IS NOT NULL THEN
        INSERT INTO linky_daily (
            date, hchp_start, hchp_end, hchc_start, hchc_end,
            hchp_kwh, hchc_kwh, total_kwh,
            avg_temp, min_temp, max_temp, data_points
        )
        VALUES (
            target_date,
            v_hchp_start, v_hchp_end, v_hchc_start, v_hchc_end,
            (v_hchp_end - v_hchp_start) / 1000,
            (v_hchc_end - v_hchc_start) / 1000,
            (v_hchp_end - v_hchp_start + v_hchc_end - v_hchc_start) / 1000,
            v_avg_temp, v_min_temp, v_max_temp, v_data_points
        )
        ON DUPLICATE KEY UPDATE
            hchp_start = v_hchp_start,
            hchp_end = v_hchp_end,
            hchc_start = v_hchc_start,
            hchc_end = v_hchc_end,
            hchp_kwh = (v_hchp_end - v_hchp_start) / 1000,
            hchc_kwh = (v_hchc_end - v_hchc_start) / 1000,
            total_kwh = (v_hchp_end - v_hchp_start + v_hchc_end - v_hchc_start) / 1000,
            avg_temp = v_avg_temp,
            min_temp = v_min_temp,
            max_temp = v_max_temp,
            data_points = v_data_points;
    END IF;
END;;

-- Procedure to refresh monthly aggregation for a specific billing period
-- billing_date format: 'YYYY-MM-DD' where DD is the jour_releve_compteur
CREATE PROCEDURE IF NOT EXISTS refresh_monthly_aggregate(IN billing_date DATE, IN reading_day TINYINT)
BEGIN
    DECLARE v_start_date DATE;
    DECLARE v_end_date DATE;
    DECLARE v_hchp_start INTEGER;
    DECLARE v_hchp_end INTEGER;
    DECLARE v_hchc_start INTEGER;
    DECLARE v_hchc_end INTEGER;
    DECLARE v_avg_temp DECIMAL(5,2);
    DECLARE v_min_temp DECIMAL(5,2);
    DECLARE v_max_temp DECIMAL(5,2);
    DECLARE v_nb_days INTEGER;
    DECLARE v_data_points INTEGER;
    
    -- Calculate the start date (previous billing date)
    SET v_start_date = DATE_SUB(billing_date, INTERVAL 1 MONTH);
    SET v_end_date = billing_date;
    
    -- Get the counter values at the exact billing time (using the reading day hour 0)
    SELECT 
        HCHP, HCHC
    INTO 
        v_hchp_start, v_hchc_start
    FROM linky_history
    WHERE DATE(time) = v_start_date 
      AND HOUR(time) = 0
    ORDER BY time ASC
    LIMIT 1;
    
    SELECT 
        HCHP, HCHC
    INTO 
        v_hchp_end, v_hchc_end
    FROM linky_history
    WHERE DATE(time) = v_end_date
      AND HOUR(time) = 0
    ORDER BY time ASC
    LIMIT 1;
    
    -- Get aggregated statistics for the period
    SELECT 
        ROUND(AVG(temperature), 2),
        ROUND(MIN(temperature), 2),
        ROUND(MAX(temperature), 2),
        DATEDIFF(v_end_date, v_start_date),
        COUNT(*)
    INTO 
        v_avg_temp, v_min_temp, v_max_temp, v_nb_days, v_data_points
    FROM linky_history
    WHERE time >= v_start_date AND time < v_end_date;
    
    -- Insert or update the monthly aggregate
    IF v_hchp_start IS NOT NULL AND v_hchp_end IS NOT NULL THEN
        INSERT INTO linky_monthly (
            billing_month, year_val, month_val, reading_day,
            hchp_start, hchp_end, hchc_start, hchc_end,
            hchp_kwh, hchc_kwh, total_kwh,
            avg_temp, min_temp, max_temp, nb_days, data_points
        )
        VALUES (
            billing_date,
            YEAR(billing_date),
            MONTH(billing_date),
            reading_day,
            v_hchp_start, v_hchp_end, v_hchc_start, v_hchc_end,
            (v_hchp_end - v_hchp_start) / 1000,
            (v_hchc_end - v_hchc_start) / 1000,
            (v_hchp_end - v_hchp_start + v_hchc_end - v_hchc_start) / 1000,
            v_avg_temp, v_min_temp, v_max_temp, v_nb_days, v_data_points
        )
        ON DUPLICATE KEY UPDATE
            hchp_start = v_hchp_start,
            hchp_end = v_hchp_end,
            hchc_start = v_hchc_start,
            hchc_end = v_hchc_end,
            hchp_kwh = (v_hchp_end - v_hchp_start) / 1000,
            hchc_kwh = (v_hchc_end - v_hchc_start) / 1000,
            total_kwh = (v_hchp_end - v_hchp_start + v_hchc_end - v_hchc_start) / 1000,
            avg_temp = v_avg_temp,
            min_temp = v_min_temp,
            max_temp = v_max_temp,
            nb_days = v_nb_days,
            data_points = v_data_points;
    END IF;
END;;

DELIMITER ;
"

echo "************* Creating events for automatic updates *************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
DELIMITER ;;

-- Event to clean old realtime data (every 1 minute)
CREATE EVENT IF NOT EXISTS clean_realtime 
ON SCHEDULE EVERY 1 MINUTE 
DO
BEGIN
    DELETE FROM linky_realtime WHERE time < NOW() - INTERVAL 2 DAY;
END;;

-- Event to refresh daily aggregates (runs at 1:00 AM every day)
-- Refreshes yesterday's data to ensure completeness
CREATE EVENT IF NOT EXISTS refresh_daily_aggregates
ON SCHEDULE EVERY 1 DAY 
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 HOUR)
DO
BEGIN
    CALL refresh_daily_aggregate(CURDATE() - INTERVAL 1 DAY);
    CALL refresh_daily_aggregate(CURDATE() - INTERVAL 2 DAY);
END;;

-- Event to refresh current day aggregate every hour
CREATE EVENT IF NOT EXISTS refresh_current_day_aggregate
ON SCHEDULE EVERY 1 HOUR
DO
BEGIN
    CALL refresh_daily_aggregate(CURDATE());
END;;

DELIMITER ;
"

echo "*******************************************"
echo "***** Done creating Linkystat schema ******"
echo "*******************************************"
