# Driver for checking weather conditions with the Open-Meteo online service

[Open-Meteo](https://open-meteo.com) is free for non-commercial use and needs no API key.
Compared with the openweathermap driver it also fills in wind gusts, feels-like temperature
and dew point, and reports wind speed in km/h (openweathermap returns m/s).

The location is given as coordinates. Rain, snow, drizzle, hail and thunderstorms (WMO weather
codes 51-67, 71-77, 80-86, 95-99) count as rain, like in the other weather drivers.

The Pi must be able to reach `api.open-meteo.com` over HTTPS.

# Example of configuration in piGarden.conf

```bash
WEATHER_SERVICE="openmeteo"

OPENMETEO_LATITUDE="43.8814"     # Set with the latitude of the garden
OPENMETEO_LONGITUDE="10.7976"    # Set with the longitude of the garden
OPENMETEO_CITY="Pieve a Nievole" # Name shown in piGardenWeb (optional)
OPENMETEO_TZ="Europe/Rome"       # Set with your time zone (optional, default: from the coordinates)
```
