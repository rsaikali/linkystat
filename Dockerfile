FROM python:3.12-slim

ENV LINKY_USB_DEVICE /dev/ttyACM0

ENV MYSQL_HOST db
ENV MYSQL_PORT 3306
ENV MYSQL_NAME linky
ENV MYSQL_USER mysql_user
ENV MYSQL_PASSWORD mysql_password

ENV PYTHONUNBUFFERED 1
ENV PIP_ROOT_USER_ACTION=ignore
ENV TZ "Europe/Paris"

RUN mkdir /app
WORKDIR /app

COPY requirements.txt .
COPY src .

RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

CMD  ["sh", "-c", "cd /app/src && python linky2db.py"]