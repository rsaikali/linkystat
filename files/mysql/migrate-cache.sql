-- Migration script for existing LinkyStats databases.
-- Apply manually on production without recreating the whole schema.

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

CREATE INDEX idx_linky_realtime_time_hchx ON linky_realtime (time, HCHP, HCHC);
CREATE INDEX idx_linky_history_time_hchx ON linky_history (time, HCHP, HCHC);
CREATE INDEX idx_linky_history_time_temp ON linky_history (time, temperature);

DROP PROCEDURE IF EXISTS refresh_linky_cache;
DELIMITER ;;
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
DELIMITER ;

DROP EVENT IF EXISTS refresh_linky_cache_event;
DELIMITER ;;
CREATE EVENT refresh_linky_cache_event ON SCHEDULE EVERY 5 MINUTE
DO
BEGIN
    CALL refresh_linky_cache();
END;;
DELIMITER ;

CALL refresh_linky_cache();
