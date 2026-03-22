#/bin/sh -xe

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

echo "************* Creating tables *************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
CREATE TABLE IF NOT EXISTS linky_realtime (
    time DATETIME NOT NULL,
    PAPP SMALLINT UNSIGNED NOT NULL,
    HCHP INTEGER UNSIGNED NOT NULL,
    HCHC INTEGER UNSIGNED NOT NULL,
    temperature double,
    libelle_tarif VARCHAR(16),
    PRIMARY KEY (time)
);

CREATE TABLE IF NOT EXISTS linky_history (
    time datetime NOT NULL,
    HCHC INTEGER UNSIGNED DEFAULT 0,
    HCHP INTEGER UNSIGNED DEFAULT 0,
    temperature double,
    PRIMARY KEY (time)
);

CREATE TABLE IF NOT EXISTS linky_daily_cache (
    day_date DATE NOT NULL,
    HCHC_delta INTEGER UNSIGNED NOT NULL DEFAULT 0,
    HCHP_delta INTEGER UNSIGNED NOT NULL DEFAULT 0,
    total_kwh DOUBLE NOT NULL DEFAULT 0,
    temperature_avg DOUBLE,
    updated_at DATETIME NOT NULL,
    PRIMARY KEY (day_date)
);

CREATE TABLE IF NOT EXISTS linky_period_cache (
    period_type ENUM('month', 'year') NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    HCHC_delta BIGINT UNSIGNED NOT NULL DEFAULT 0,
    HCHP_delta BIGINT UNSIGNED NOT NULL DEFAULT 0,
    total_kwh DOUBLE NOT NULL DEFAULT 0,
    updated_at DATETIME NOT NULL,
    PRIMARY KEY (period_type, period_start),
    KEY idx_period_type_end (period_type, period_end)
);
"

echo "************* Creating indexes *************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
SELECT IF(
    COUNT(*) = 0,
    'ALTER TABLE linky_realtime ADD INDEX idx_linky_realtime_time_hchx (time, HCHP, HCHC)',
    'SELECT 1'
) INTO @sql FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = '${MYSQL_DATABASE}' AND INDEX_NAME = 'idx_linky_realtime_time_hchx';
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SELECT IF(
    COUNT(*) = 0,
    'ALTER TABLE linky_history ADD INDEX idx_linky_history_time_hchx (time, HCHP, HCHC)',
    'SELECT 1'
) INTO @sql FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = '${MYSQL_DATABASE}' AND INDEX_NAME = 'idx_linky_history_time_hchx';
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SELECT IF(
    COUNT(*) = 0,
    'ALTER TABLE linky_history ADD INDEX idx_linky_history_time_temp (time, temperature)',
    'SELECT 1'
) INTO @sql FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = '${MYSQL_DATABASE}' AND INDEX_NAME = 'idx_linky_history_time_temp';
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
"

echo "************ Creating triggers ************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
DROP TRIGGER IF EXISTS realtime_trigger;
delimiter ;;
CREATE TRIGGER realtime_trigger AFTER INSERT ON linky_realtime FOR EACH ROW
BEGIN
	INSERT INTO linky_history (time, HCHC, HCHP, temperature)
	VALUES(
		STR_TO_DATE(DATE_FORMAT(DATE_ADD(now(), INTERVAL 1 HOUR), '%Y-%m-%d %H:00:00'), '%Y-%m-%d %T'),
		new.HCHC,
		new.HCHP,
		new.temperature)
    ON DUPLICATE KEY UPDATE HCHC=new.HCHC, HCHP=new.HCHP, temperature=new.temperature;
END;;
delimiter ;
"

echo "************* Creating events *************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
DROP PROCEDURE IF EXISTS refresh_linky_cache;
delimiter ;;
CREATE PROCEDURE refresh_linky_cache()
BEGIN
    INSERT INTO linky_daily_cache (day_date, HCHC_delta, HCHP_delta, total_kwh, temperature_avg, updated_at)
    SELECT
        DATE(time) AS day_date,
        MAX(HCHC) - MIN(HCHC) AS HCHC_delta,
        MAX(HCHP) - MIN(HCHP) AS HCHP_delta,
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh,
        ROUND(AVG(temperature), 2) AS temperature_avg,
        NOW() AS updated_at
    FROM linky_history
    GROUP BY DATE(time)
    ON DUPLICATE KEY UPDATE
        HCHC_delta = VALUES(HCHC_delta),
        HCHP_delta = VALUES(HCHP_delta),
        total_kwh = VALUES(total_kwh),
        temperature_avg = VALUES(temperature_avg),
        updated_at = VALUES(updated_at);

    INSERT INTO linky_period_cache (period_type, period_start, period_end, HCHC_delta, HCHP_delta, total_kwh, updated_at)
    SELECT
        'month' AS period_type,
        period_start,
        DATE_ADD(period_start, INTERVAL 1 MONTH) AS period_end,
        MAX(HCHC) - MIN(HCHC) AS HCHC_delta,
        MAX(HCHP) - MIN(HCHP) AS HCHP_delta,
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh,
        NOW() AS updated_at
    FROM (
        SELECT
            time,
            HCHC,
            HCHP,
            CASE
                WHEN DAY(time) >= 24 THEN STR_TO_DATE(DATE_FORMAT(time, '%Y-%m-24'), '%Y-%m-%d')
                ELSE STR_TO_DATE(DATE_FORMAT(DATE_SUB(time, INTERVAL 1 MONTH), '%Y-%m-24'), '%Y-%m-%d')
            END AS period_start
        FROM linky_history
    ) AS month_data
    GROUP BY period_start
    ON DUPLICATE KEY UPDATE
        period_end = VALUES(period_end),
        HCHC_delta = VALUES(HCHC_delta),
        HCHP_delta = VALUES(HCHP_delta),
        total_kwh = VALUES(total_kwh),
        updated_at = VALUES(updated_at);

    INSERT INTO linky_period_cache (period_type, period_start, period_end, HCHC_delta, HCHP_delta, total_kwh, updated_at)
    SELECT
        'year' AS period_type,
        period_start,
        DATE_ADD(period_start, INTERVAL 1 YEAR) AS period_end,
        MAX(HCHC) - MIN(HCHC) AS HCHC_delta,
        MAX(HCHP) - MIN(HCHP) AS HCHP_delta,
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh,
        NOW() AS updated_at
    FROM (
        SELECT
            time,
            HCHC,
            HCHP,
            CASE
                WHEN time >= STR_TO_DATE(CONCAT(YEAR(time), '-12-24'), '%Y-%m-%d') THEN STR_TO_DATE(CONCAT(YEAR(time), '-12-24'), '%Y-%m-%d')
                ELSE STR_TO_DATE(CONCAT(YEAR(time) - 1, '-12-24'), '%Y-%m-%d')
            END AS period_start
        FROM linky_history
    ) AS year_data
    GROUP BY period_start
    ON DUPLICATE KEY UPDATE
        period_end = VALUES(period_end),
        HCHC_delta = VALUES(HCHC_delta),
        HCHP_delta = VALUES(HCHP_delta),
        total_kwh = VALUES(total_kwh),
        updated_at = VALUES(updated_at);
END;;

DROP EVENT IF EXISTS clean_realtime;
CREATE EVENT clean_realtime ON SCHEDULE EVERY 6 HOUR
DO
BEGIN
	DELETE FROM linky_realtime WHERE time < NOW() - INTERVAL 2 DAY;
END;;

DROP EVENT IF EXISTS refresh_linky_cache_event;
CREATE EVENT refresh_linky_cache_event ON SCHEDULE EVERY 5 MINUTE
DO
BEGIN
	CALL refresh_linky_cache();
END;;

CALL refresh_linky_cache();
delimiter ;
"

echo "*******************************************"
echo "***** Done creating Linkystat schema ******"
echo "*******************************************"