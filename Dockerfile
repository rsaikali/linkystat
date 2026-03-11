FROM python:3.12-slim

ENV LINKY_USB_DEVICE /dev/ttyACM0

ENV OPENWEATHER_API_KEY xxxxxxxxxxxxxxxxxxxxxxxxx
ENV OPENWEATHER_LATITUDE 47.3389
ENV OPENWEATHER_LONGITUDE 0.6892

ENV MYSQL_HOST db
ENV MYSQL_PORT 3306
ENV MYSQL_NAME linky
ENV MYSQL_USER mysql_user
ENV MYSQL_PASSWORD mysql_password

ENV PYTHONUNBUFFERED 1
ENV PIP_ROOT_USER_ACTION=ignore
ENV TZ "Europe/Paris"

WORKDIR /app

COPY requirements.txt .
COPY src .

RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

CMD  ["python", "linky2db.py"]