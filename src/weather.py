import requests
import logging
from cachetools import cachedmethod, TTLCache

logging.basicConfig(format="[%(asctime)s %(levelname)s/%(module)s] %(message)s",
                    datefmt="%Y-%m-%d %H:%M:%S",
                    level=logging.INFO)


class TemperatureManager(object):

    def __init__(self, openweather_api_key, latitude, longitude):
        self.openweather_api_key = openweather_api_key
        self.latitude = latitude
        self.longitude = longitude
        self.cache = TTLCache(maxsize=16, ttl=600)

    @cachedmethod(lambda self: self.cache)
    def get_current_temperature(self):
        url = f"http://api.openweathermap.org/data/2.5/weather?lat={self.latitude}&lon={self.longitude}&appid={self.openweather_api_key}&type=accurate&units=metric&lang=fr"
        temperature = round(requests.get(url).json()['main']['temp'], 2)
        logging.info(f"Calling OpenWeather API for current temperature: {temperature}°C")
        return temperature
