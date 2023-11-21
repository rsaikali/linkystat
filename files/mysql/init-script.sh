#/bin/sh -xe

echo "*********************************"
echo "*** Creating Linkystat schema ***"
echo "*********************************"


echo "*** Creating ${GRAFANA_MYSQL_USER} user ***"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
CREATE USER '${GRAFANA_MYSQL_USER}' IDENTIFIED BY '${GRAFANA_MYSQL_PASSWORD}';
GRANT SELECT, SHOW VIEW ON ${MYSQL_DATABASE}.* TO '${GRAFANA_MYSQL_USER}';
FLUSH PRIVILEGES;
"

echo "*** Creating tables ***"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
CREATE TABLE IF NOT EXISTS linky_realtime (
    time DATETIME NOT NULL,
    PAPP DOUBLE NOT NULL,
    HCHP DOUBLE NOT NULL,
    HCHC DOUBLE NOT NULL,
    PRIMARY KEY (time)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS linky_history (
    time datetime NOT NULL,
    HCHC double DEFAULT 0,
    HCHP double DEFAULT 0,
    PRIMARY KEY (time)
) ENGINE=InnoDB;
"

echo "*** Creating views ***"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
CREATE OR REPLACE VIEW monthly_history AS
    SELECT
	    DATE_FORMAT(MAX(DATE_ADD(DATE_SUB(time, INTERVAL ${DAYS_OFFSET} DAY), INTERVAL 1 MONTH)), '%Y-%m') AS provider_time,
	    (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh
    FROM linky_history
    WHERE time > DATE_SUB(NOW(), INTERVAL 1 MONTH)
    UNION
    SELECT 
        DATE_FORMAT(MIN(DATE_ADD(time, INTERVAL ${DAYS_OFFSET} DAY)), '%Y-%m') AS provider_time,
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh
    FROM linky_history
    WHERE MONTH(DATE_SUB(time, INTERVAL ${DAYS_OFFSET} DAY)) != MONTH(DATE_SUB(now(), INTERVAL ${DAYS_OFFSET} DAY))
    GROUP BY MONTH(DATE_SUB(time, INTERVAL ${DAYS_OFFSET} DAY)), YEAR(DATE_SUB(time, INTERVAL ${DAYS_OFFSET} DAY))
    ORDER BY provider_time DESC;

CREATE OR REPLACE VIEW yearly_history AS
    SELECT
        DATE_FORMAT(MAX(DATE_ADD(time, INTERVAL ${DAYS_OFFSET} DAY)), '%Y') AS provider_time,
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh
    FROM linky_history
    WHERE time > DATE_SUB(NOW(), INTERVAL 1 YEAR)
    UNION
    SELECT 
        DATE_FORMAT(MIN(DATE_ADD(time, INTERVAL ${DAYS_OFFSET} DAY)), '%Y') AS provider_time,
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh
    FROM linky_history
    GROUP BY YEAR(DATE_ADD(DATE_SUB(time, INTERVAL ${DAYS_OFFSET} DAY), INTERVAL 1 MONTH))
    HAVING MIN(time) < DATE_SUB(now(), INTERVAL 1 YEAR)
    AND MONTH(MIN(time)) = 12
    ORDER BY provider_time DESC;
"

echo "*** Creating triggers ***"
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

echo "*** Creating events ***"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
delimiter ;;
CREATE EVENT IF NOT EXISTS clean_realtime ON SCHEDULE EVERY 1 MINUTE 
DO
BEGIN
	DELETE FROM linky_realtime WHERE time < NOW() - INTERVAL 1 YEAR;
END;;
delimiter ;
"

echo "**************************************"
echo "*** Done creating Linkystat schema ***"
echo "**************************************"