import json
import logging
import os
import time
from datetime import datetime

import paho.mqtt.client as mqtt
import sqlalchemy as sa

from weather import TemperatureManager

logging.basicConfig(format="[%(asctime)s %(levelname)s/%(module)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S", level=logging.INFO)

# MySQL
MYSQL_HOST = os.getenv("MYSQL_HOST")
MYSQL_PORT = int(os.getenv("MYSQL_PORT", 3306))
MYSQL_NAME = os.getenv("MYSQL_NAME")
MYSQL_USER = os.getenv("MYSQL_USER")
MYSQL_PASSWORD = os.getenv("MYSQL_PASSWORD")
CONNECTION_STRING = f"mysql+pymysql://{MYSQL_USER}:{MYSQL_PASSWORD}@{MYSQL_HOST}:{MYSQL_PORT}/{MYSQL_NAME}"

# OpenWeather
OPENWEATHER_API_KEY = os.getenv("OPENWEATHER_API_KEY", None)
OPENWEATHER_LATITUDE = float(os.getenv("OPENWEATHER_LATITUDE"))
OPENWEATHER_LONGITUDE = float(os.getenv("OPENWEATHER_LONGITUDE"))

# MQTT / Zigbee2MQTT
MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", 1883))
MQTT_USERNAME = os.getenv("MQTT_USERNAME", None)
MQTT_PASSWORD_ENV = os.getenv("MQTT_PASSWORD", None)
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "zigbee/Linky")

# ZLinky_TIC field mapping — Z2M decoded names (LiXee firmware v17, standard TIC mode).
# Z2M maps raw TIC labels to descriptive keys; override with MQTT_FIELD_* if needed.
MQTT_FIELD_PAPP = os.getenv("MQTT_FIELD_PAPP", "apparent_power")                   # VA (int)
MQTT_FIELD_HCHC = os.getenv("MQTT_FIELD_HCHC", "current_tier1_summ_delivered")     # kWh (float)
MQTT_FIELD_HCHP = os.getenv("MQTT_FIELD_HCHP", "current_tier2_summ_delivered")     # kWh (float)
MQTT_FIELD_LTARF = os.getenv("MQTT_FIELD_LTARF", "tariff_period")                  # str
MQTT_FIELD_DATE = os.getenv("MQTT_FIELD_DATE", "current_date")                     # TIC format H251202125312

# Z2M reports energy indexes in kWh; DB schema expects Wh → multiply by 1000.
# Set MQTT_ENERGY_SCALE=1 if your device already reports in Wh.
MQTT_ENERGY_SCALE = int(os.getenv("MQTT_ENERGY_SCALE", 1000))


class LinkyDataFromMQTT:
    """
    Reads Linky data from Zigbee2MQTT (ZLinky_TIC / LiXee) and writes to MySQL.

    Subscribes to a single Zigbee2MQTT topic and maps the JSON payload
    to the same linky_realtime schema used by the USB path.

    Defaults match LiXee ZLinky_TIC firmware v17, standard TIC mode, Z2M decoded keys.
    Energy indexes (HCHC/HCHP) arrive in kWh → converted to Wh via MQTT_ENERGY_SCALE.
    """

    def __init__(self):
        if OPENWEATHER_API_KEY is not None:
            self.temperature_manager = TemperatureManager(OPENWEATHER_API_KEY, OPENWEATHER_LATITUDE, OPENWEATHER_LONGITUDE)
        else:
            logging.warning("OPENWEATHER_API_KEY not set. Temperature will not be retrieved.")
            self.temperature_manager = None

        logging.info(f"Connecting to database on {MYSQL_HOST}")
        self.engine = sa.create_engine(CONNECTION_STRING, pool_pre_ping=True)
        logging.info(f"Connected to database: {self.engine.url}")

        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
        if MQTT_USERNAME:
            self.client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD_ENV)
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect

    def _on_connect(self, client, userdata, flags, reason_code, properties):
        if reason_code == 0:
            logging.info(f"Connected to MQTT broker {MQTT_HOST}:{MQTT_PORT}, subscribing to {MQTT_TOPIC}")
            client.subscribe(MQTT_TOPIC)
        else:
            logging.error(f"MQTT connection failed: reason_code={reason_code}")

    def _on_disconnect(self, client, userdata, disconnect_flags, reason_code, properties):
        logging.warning(f"MQTT disconnected (reason_code={reason_code}), reconnecting in 5s...")
        time.sleep(5)

    def _on_message(self, client, userdata, msg):
        try:
            payload = json.loads(msg.payload.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            logging.error(f"Cannot decode MQTT payload: {e}")
            return

        # Validate required fields
        required = {MQTT_FIELD_PAPP, MQTT_FIELD_HCHC, MQTT_FIELD_HCHP, MQTT_FIELD_LTARF}
        missing = required - payload.keys()
        if missing:
            logging.debug(f"Incomplete Z2M payload, missing: {missing}")
            return

        # Parse timestamp: use DATE from TIC frame if present, else now()
        date_raw = payload.get(MQTT_FIELD_DATE)
        if date_raw:
            try:
                # TIC format: H240601120000 (H + YYMMDDHHmmss)
                timestamp = datetime.strptime(str(date_raw)[1:], "%y%m%d%H%M%S").strftime("%Y-%m-%d %H:%M:%S")
            except (ValueError, IndexError):
                timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        else:
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        papp = int(payload[MQTT_FIELD_PAPP])
        hchc = int(float(payload[MQTT_FIELD_HCHC]) * MQTT_ENERGY_SCALE)
        hchp = int(float(payload[MQTT_FIELD_HCHP]) * MQTT_ENERGY_SCALE)
        ltarf = str(payload[MQTT_FIELD_LTARF]).strip()

        logging.info(f"Z2M packet [{MQTT_TOPIC}] PAPP={papp}W HCHC={hchc}Wh HCHP={hchp}Wh LTARF={ltarf}")

        current_temperature = None
        if self.temperature_manager is not None:
            current_temperature = self.temperature_manager.get_current_temperature()

        try:
            with self.engine.begin() as connection:
                connection.execute(
                    sa.text(
                        """
                        INSERT INTO linky_realtime (time, HCHC, HCHP, PAPP, temperature, libelle_tarif)
                        VALUES (:timestamp, :hchc, :hchp, :papp, :temperature, :ltarf)
                        """
                    ),
                    {"timestamp": timestamp, "hchc": hchc, "hchp": hchp, "papp": papp, "temperature": current_temperature, "ltarf": ltarf},
                )
        except sa.exc.SQLAlchemyError as e:
            logging.error(f"Database insertion error: {e}")

    def get_data(self):
        """Connect to MQTT broker and block forever (same interface as LinkyData)."""
        logging.info(f"Connecting to MQTT broker {MQTT_HOST}:{MQTT_PORT}")
        self.client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
        self.client.loop_forever(retry_first_connection=True)
