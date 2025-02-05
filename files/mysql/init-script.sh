#/bin/sh -xe

unset MYSQL_HOST
unset MYSQL_PORT

echo "*********************************"
echo "*** Creating Linkystat schema ***"
echo "*********************************"

echo "********** Creating ${GRAFANA_MYSQL_USER} user **********"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
CREATE USER '${GRAFANA_MYSQL_USER}' IDENTIFIED BY '${GRAFANA_MYSQL_PASSWORD}';
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
"

echo "************ Creating triggers ************"
mysql -u root -p${MYSQL_ROOT_PASSWORD} ${MYSQL_DATABASE} --execute \
"
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
delimiter ;;
CREATE EVENT IF NOT EXISTS clean_realtime ON SCHEDULE EVERY 1 MINUTE 
DO
BEGIN
	DELETE FROM linky_realtime WHERE time < NOW() - INTERVAL 2 DAY;
END;;
delimiter ;
"

echo "*******************************************"
echo "***** Done creating Linkystat schema ******"
echo "*******************************************"