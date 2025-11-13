import requests
import logging
from cachetools import cachedmethod, TTLCache

logging.basicConfig(format="[%(asctime)s %(levelname)s/%(module)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S", level=logging.INFO)


class TemperatureManager(object):
    """
    Weather data enrichment agent.

    This agent retrieves current temperature via OpenWeather API
    and provides intelligent caching to optimize API calls.

    :param openweather_api_key: OpenWeather API key
    :type openweather_api_key: str
    :param latitude: Geographic latitude for location
    :type latitude: float
    :param longitude: Geographic longitude for location
    :type longitude: float

    .. note::
       Cache TTL is configured to 600 seconds (10 minutes) to avoid
       excessive API calls while keeping data fresh.
    """

    def __init__(self, openweather_api_key, latitude, longitude):
        """
        Initialize temperature manager with API parameters.

        :param openweather_api_key: Valid OpenWeather API key
        :type openweather_api_key: str
        :param latitude: Latitude (-90 to +90)
        :type latitude: float
        :param longitude: Longitude (-180 to +180)
        :type longitude: float
        """
        self.openweather_api_key = openweather_api_key
        self.latitude = latitude
        self.longitude = longitude
        self.cache = TTLCache(maxsize=16, ttl=600)

    @cachedmethod(lambda self: self.cache)
    def get_current_temperature(self):
        """
        Retrieve current temperature via OpenWeather API.

        Uses TTL cache to avoid repeated API calls.
        Temperature is rounded to 2 decimal places for consistency.

        :return: Current temperature in degrees Celsius
        :rtype: float
        :raises requests.exceptions.RequestException: On API error
        :raises KeyError: If API response is malformed

        .. note::
           Method is automatically cached for 10 minutes.
           Successive calls within this period return cached value.
        """
        try:
            url = f"http://api.openweathermap.org/data/2.5/weather?lat={self.latitude}&lon={self.longitude}&appid={self.openweather_api_key}&type=accurate&units=metric&lang=fr"
            response = requests.get(url, timeout=10)
            response.raise_for_status()
            temperature = round(response.json()["main"]["temp"], 2)
            logging.info(f"Calling OpenWeather API for current temperature: {temperature}°C")
            return temperature
        except requests.exceptions.RequestException as e:
            logging.error(f"Error calling OpenWeather API: {e}")
            raise
        except KeyError as e:
            logging.error(f"Malformed OpenWeather API response, missing key: {e}")
            raise
