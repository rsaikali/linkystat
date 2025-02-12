import logging
import os
import time
from datetime import datetime

import serial
import sqlalchemy as sa

from weather import TemperatureManager

logging.basicConfig(format="[%(asctime)s %(levelname)s/%(module)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S", level=logging.INFO)

# MySQL database
MYSQL_HOST = os.getenv("MYSQL_HOST")
MYSQL_PORT = int(os.getenv("MYSQL_PORT", 3306))
MYSQL_NAME = os.getenv("MYSQL_NAME")
MYSQL_USER = os.getenv("MYSQL_USER")
MYSQL_PASSWORD = os.getenv("MYSQL_PASSWORD")
CONNECTION_STRING = f"mysql+pymysql://{MYSQL_USER}:{MYSQL_PASSWORD}@{MYSQL_HOST}:{MYSQL_PORT}/{MYSQL_NAME}"

# OpenWeather API
OPENWEATHER_API_KEY = os.getenv("OPENWEATHER_API_KEY", None)
OPENWEATHER_LATITUDE = float(os.getenv("OPENWEATHER_LATITUDE"))
OPENWEATHER_LONGITUDE = float(os.getenv("OPENWEATHER_LONGITUDE"))

# Port serial
LINKY_USB_DEVICE = os.getenv("LINKY_USB_DEVICE", "/dev/null")
LINKY_BAUDRATE = int(os.getenv("LINKY_BAUDRATE", 9600))
KEEP_KEYS = {"DATE": "DATE", "SINSTS": "PAPP", "EASF01": "HCHC", "EASF02": "HCHP", "LTARF": "LTARF"}


class LinkyData(object):
    """
    This code is used to retrieve real-time data from a Linky device (French electricity meter).
    The data is stored in a MySQL database.
    """

    def __init__(self):
        # Openweather
        if OPENWEATHER_API_KEY is not None:
            self.temperature_manager = TemperatureManager(OPENWEATHER_API_KEY, OPENWEATHER_LATITUDE, OPENWEATHER_LONGITUDE)
        else:
            logging.warning("OPENWEATHER_API_KEY is not set. Temperature will not be retrieved.")
            self.temperature_manager = None

        # Initialize Linky USB device
        logging.info(f"Connecting to Linky through USB device: {LINKY_USB_DEVICE}")
        self.serial_port = serial.Serial(port=LINKY_USB_DEVICE, baudrate=LINKY_BAUDRATE, parity=serial.PARITY_EVEN, stopbits=serial.STOPBITS_ONE, bytesize=serial.SEVENBITS, timeout=1)
        logging.info("Connected to Linky: %s" % self.serial_port.get_settings())

        # Initialize MySQL database engine
        logging.info(f"Connecting to database on {MYSQL_HOST}")
        self.engine = sa.create_engine(CONNECTION_STRING)
        logging.info(f"Connected to database: {self.engine.url}")

    def get_data(self):
        """
        This method reads data from the Linky device and stores it in the database.
        """
        data = {}

        with self.serial_port as ser:
            # Continuously read lines from the serial port
            while True:
                line = ser.readline()

                # Check if the line contains the start of a new packet
                if b"\x03\x02" in bytearray(line):
                    data = {}

                # Decode the line and split it into an array
                arr = line.decode("ascii").strip().split()

                # Check if the array has the expected number of elements
                if len(arr) < 3:
                    # Skip this line and continue to the next one
                    continue

                # Extract the key, value, and checksum from the array
                key, value, checksum = arr[0], " ".join(arr[1:-1]), arr[-1]

                # Check if the key is one of the expected ones and if the checksum is correct
                if key not in KEEP_KEYS.keys() or not LinkyData.verify_checksum(key, value, checksum):
                    continue

                # Store value in current dataframe
                data[KEEP_KEYS[key]] = value

                # Check if all expected keys have been processed
                if len(data.keys()) == len(KEEP_KEYS.keys()):

                    # Get timestamp from dataframe
                    timestamp = datetime.strptime(data["DATE"][1:], "%y%m%d%H%M%S").strftime("%Y-%m-%d %H:%M:%S")

                    # Log the received packet information
                    logging.info(f"Received new packet from '{LINKY_USB_DEVICE}' Linky device [PAPP={int(data['PAPP'])} HCHP={int(data['HCHP'])} HCHC={int(data['HCHC'])} LTARF={data['LTARF']}]")

                    # Gettting current temperature from OpenWeather API
                    if self.temperature_manager is not None:
                        current_temperature = self.temperature_manager.get_current_temperature()
                    else:
                        current_temperature = None

                    # Write the received data to the database
                    with self.engine.begin() as connection:
                        # Prepare the SQL query to insert the data into the table
                        sql_query = f"""
                            INSERT INTO linky_realtime (time, HCHC, HCHP, PAPP, temperature, libelle_tarif)
                            VALUES ('{timestamp}', {data['HCHC']}, {data['HCHP']}, {data['PAPP']}, {current_temperature}, '{data['LTARF']}')
                        """
                        # Execute the SQL query
                        connection.execute(sa.sql.text(sql_query))

    @staticmethod
    def verify_checksum(key, value, checksum):
        """
        Verify the checksum of the provided key-value pair.

        Parameters:
        - key (str): The key of the data.
        - value (str): The value of the data.
        - checksum (str): The expected checksum.

        Returns:
        - is_valid (bool): True if the checksum is valid, False otherwise.
        """
        # Don't verify checksum for DATE
        if key == "DATE":
            return True

        # Convert the key, value, and tab character into a list of ASCII values
        checked_data = [ord(c) for c in (key + "\t" + value + "\t")]

        # Compute the sum of the ASCII values and apply bitwise AND with 0x3F to get the least significant 6 bits
        # Add 0x20 to set the 7th bit to 1
        computed_sum = (sum(checked_data) & 0x3F) + 0x20

        # Convert the computed sum back into a character
        computed_checksum = chr(computed_sum)

        # Check if the computed checksum matches the expected checksum
        is_valid = checksum == computed_checksum

        # If the checksum is not valid, log an error message with the current time, the key-value pair, and the expected and actual checksums
        now = datetime.now().strftime("%H:%M:%S")
        if not is_valid:
            logging.error(f"Invalid Linky data checksum at {now} for {key}={value} -> Expected '{checksum}' got '{chr(computed_sum)}'")
        else:
            logging.info(f"Valid Linky data checksum at {now} for {key}={value} -> Checksum is '{chr(computed_sum)}'")
        return is_valid


class LinkyDataFromProd(object):
    def __init__(self):
        # Production MySQL database (for dev, we get data from production)
        PRODUCTION_DB_HOST = os.getenv("PRODUCTION_DB_HOST")
        PRODUCTION_DB_PORT = int(os.getenv("PRODUCTION_DB_PORT", 3306))
        PRODUCTION_DB_NAME = os.getenv("PRODUCTION_DB_NAME")
        PRODUCTION_DB_USER = os.getenv("PRODUCTION_DB_USER")
        PRODUCTION_DB_PASSWORD = os.getenv("PRODUCTION_DB_PASSWORD")
        PRODUCTION_CONNECTION_STRING = f"mysql+pymysql://{PRODUCTION_DB_USER}:{PRODUCTION_DB_PASSWORD}@{PRODUCTION_DB_HOST}:{PRODUCTION_DB_PORT}/{PRODUCTION_DB_NAME}"

        # SQLAlchemy production MySQL engine
        logging.info(f"Connecting to database on {PRODUCTION_DB_HOST}")
        self.production_engine = sa.create_engine(PRODUCTION_CONNECTION_STRING)
        logging.info(f"Connected to database: {self.production_engine.url}")

        # SQLAlchemy MySQL engine
        logging.info(f"Connecting to database on {MYSQL_HOST}")
        self.engine = sa.create_engine(CONNECTION_STRING)
        logging.info(f"Connected to database: {self.engine.url}")

        self.last_linky_data = ()

    def get_data(self):
        """
        Retrieves the latest data from a production database (self.prod_engine).

        It does so by executing a SQL query on production database to get the latest data from a table named 'linky_realtime'.
        If the production database is unavailable, the method logs a warning message.

        If the retrieved data is equivalent to the last saved data (self.last_linky_data), the method waits before starting the loop again.

        If there is new data, it is inserted into a table in development database.
        Finally, the method pauses before starting the next iteration of the loop.
        """
        while True:
            with self.production_engine.connect() as con:
                rs = con.execute(sa.text("SELECT time, PAPP, HCHP, HCHC, temperature, libelle_tarif FROM linky_realtime ORDER BY time DESC LIMIT 1"))
                row = list(rs)[0]

            if self.last_linky_data == row:
                time.sleep(1)
                continue

            with self.engine.connect() as con:
                try:
                    stmt = sa.text("INSERT INTO linky_realtime (time, PAPP, HCHP, HCHC, temperature, libelle_tarif) VALUES (:time, :PAPP, :HCHP, :HCHC, :temperature, :libelle_tarif)")
                    stmt = stmt.bindparams(time=row[0], PAPP=row[1], HCHP=row[2], HCHC=row[3], temperature=row[4], libelle_tarif=row[5])
                    params = stmt.compile().params
                    logging.info(
                        f"Got new Linky data from production environment at {params['time']}: PAPP={params['PAPP']} HCHP={params['HCHP']} HCHC={params['HCHC']}, temperature={params['temperature']}, libelle_tarif={params['libelle_tarif']}"
                    )
                    con.execute(stmt)
                    con.commit()
                except sa.exc.IntegrityError as e:
                    logging.error(e)

            self.last_linky_data = row
            time.sleep(1)


if __name__ == "__main__":
    try:
        # Get realtime data from USB TeleInfo
        ld = LinkyData()
    except serial.serialutil.SerialException:
        # In development, we don't have USB serial connection to Linky device. We'll get realtime data from production environment.
        logging.warning("Cannot establish direct USB connection to Linky device, getting data from production database...")
        ld = LinkyDataFromProd()

    ld.get_data()
