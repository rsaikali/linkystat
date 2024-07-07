#/bin/sh -xe

unset MYSQL_HOST
unset MYSQL_PORT

echo "*********************************"
echo "*** Creating Linkystat schema ***"
echo "*********************************"

echo "*********** Creating functions ************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
DELIMITER ;;

CREATE FUNCTION getNbDaysCurrentPeriod() RETURNS INT DETERMINISTIC NO SQL
    BEGIN
		RETURN 
			CASE WHEN DAYOFMONTH(current_date) <= ${DAYS_OFFSET}
				THEN DAYOFMONTH(LAST_DAY(DATE_ADD(
						DATE_SUB(current_date, interval 1 month), 
						interval ${DAYS_OFFSET} - DAYOFMONTH(current_date) day)))                     
				ELSE DAYOFMONTH(LAST_DAY(date_add(current_date, interval ${DAYS_OFFSET} - DAYOFMONTH(current_date) day)))
			END;
    END;;

CREATE FUNCTION getNbDaysCurrentYear() RETURNS INT DETERMINISTIC
    BEGIN
        RETURN DAYOFYEAR(CONCAT(YEAR(LAST_DAY(DATE_ADD(DATE_SUB(NOW(), INTERVAL ${DAYS_OFFSET} DAY), INTERVAL 1 MONTH))),'-12-31'));
    END;;

DELIMITER ;
"

echo "********** Creating ${GRAFANA_MYSQL_USER} user **********"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
CREATE USER '${GRAFANA_MYSQL_USER}' IDENTIFIED BY '${GRAFANA_MYSQL_PASSWORD}';
GRANT SELECT, SHOW VIEW, EXECUTE ON ${MYSQL_DATABASE}.* TO '${GRAFANA_MYSQL_USER}';
GRANT EXECUTE ON FUNCTION ${MYSQL_DATABASE}.getNbDaysCurrentPeriod TO '${GRAFANA_MYSQL_USER}';
GRANT EXECUTE ON FUNCTION ${MYSQL_DATABASE}.getNbDaysCurrentYear TO '${GRAFANA_MYSQL_USER}';
FLUSH PRIVILEGES;
"

echo "************* Creating tables *************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
CREATE TABLE IF NOT EXISTS linky_realtime (
    time DATETIME NOT NULL,
    PAPP DOUBLE NOT NULL,
    HCHP DOUBLE NOT NULL,
    HCHC DOUBLE NOT NULL,
    PRIMARY KEY (time)
);

CREATE TABLE IF NOT EXISTS linky_history (
    time datetime NOT NULL,
    HCHC double DEFAULT 0,
    HCHP double DEFAULT 0,
    PRIMARY KEY (time)
);
"

echo "************** Creating views *************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
CREATE OR REPLACE VIEW monthly_history AS
    SELECT
	    DATE_FORMAT(DATE_ADD(DATE_SUB(now(), INTERVAL ${DAYS_OFFSET} DAY), INTERVAL 1 MONTH), '%Y-%m') AS provider_time,
        (MAX(HCHP) - MIN(HCHP)) / 1000 AS total_hp_kwh,
        (MAX(HCHC) - MIN(HCHC)) / 1000 AS total_hc_kwh,
	    (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh
    FROM linky_history
    WHERE time BETWEEN NOW() - INTERVAL getNbDaysCurrentPeriod() DAY - INTERVAL 1 HOUR AND NOW() - INTERVAL 1 HOUR
    UNION
    SELECT
        DATE_FORMAT(MIN(DATE_ADD(time, INTERVAL ${DAYS_OFFSET} DAY)), '%Y-%m') AS provider_time,
        (MAX(HCHP) - MIN(HCHP)) / 1000 AS total_hp_kwh,
        (MAX(HCHC) - MIN(HCHC)) / 1000 AS total_hc_kwh,
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh
    FROM linky_history
    WHERE DATE_FORMAT(DATE_SUB(time, INTERVAL ${DAYS_OFFSET} DAY), '%Y-%m') < DATE_FORMAT(DATE_SUB(NOW(), INTERVAL ${DAYS_OFFSET} DAY), '%Y-%m')
    GROUP BY MONTH(DATE_SUB(time, INTERVAL ${DAYS_OFFSET} DAY)), YEAR(DATE_SUB(time, INTERVAL ${DAYS_OFFSET} DAY))
    ORDER BY provider_time DESC;

CREATE OR REPLACE VIEW yearly_history AS
    SELECT
        DATE_FORMAT(DATE_ADD(DATE_SUB(now(), INTERVAL ${DAYS_OFFSET} DAY), INTERVAL 1 MONTH), '%Y') AS provider_time,
        (MAX(HCHP) - MIN(HCHP)) / 1000 AS total_hp_kwh,
        (MAX(HCHC) - MIN(HCHC)) / 1000 AS total_hc_kwh,
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh
    FROM linky_history
    WHERE time BETWEEN NOW() - INTERVAL getNbDaysCurrentYear() DAY - INTERVAL 1 HOUR AND NOW() - INTERVAL 1 HOUR
    UNION
    SELECT
        DATE_FORMAT(MIN(DATE_ADD(time, INTERVAL ${DAYS_OFFSET} DAY)), '%Y') AS provider_time,
        (MAX(HCHP) - MIN(HCHP)) / 1000 AS total_hp_kwh,
        (MAX(HCHC) - MIN(HCHC)) / 1000 AS total_hc_kwh,
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh
    FROM linky_history
    GROUP BY YEAR(DATE_ADD(DATE_SUB(time, INTERVAL ${DAYS_OFFSET} DAY), INTERVAL 1 MONTH))
    HAVING MIN(time) < DATE_SUB(NOW(), INTERVAL 1 YEAR)
    AND MONTH(MIN(time)) = 12
    ORDER BY provider_time DESC;
"

echo "************ Creating triggers ************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
delimiter ;;
CREATE TRIGGER realtime_trigger AFTER INSERT ON linky_realtime FOR EACH ROW
BEGIN
	INSERT INTO linky_history (time, HCHC, HCHP)
	VALUES(
		STR_TO_DATE(DATE_FORMAT(DATE_ADD(now(), INTERVAL 1 HOUR), '%Y-%m-%d %H:00:00'), '%Y-%m-%d %T'),
		new.HCHC,
		new.HCHP)
    ON DUPLICATE KEY UPDATE HCHC=new.HCHC, HCHP=new.HCHP;
END;;
delimiter ;
"

echo "************* Creating events *************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
delimiter ;;
CREATE EVENT IF NOT EXISTS clean_realtime ON SCHEDULE EVERY 1 MINUTE 
DO
BEGIN
	DELETE FROM linky_realtime WHERE time < NOW() - INTERVAL 1 DAY;
END;;
delimiter ;
"

echo "*******************************************"
echo "***** Done creating Linkystat schema ******"
echo "*******************************************"