FROM python:3.11-slim

ENV LINKY_USB_DEVICE /dev/ttyACM0

ENV DB_HOST db
ENV DB_PORT 3306
ENV DB_NAME linky
ENV DB_USER mysql_user
ENV DB_PASSWORD mysql_password

ENV PYTHONUNBUFFERED 1
ENV PIP_ROOT_USER_ACTION=ignore
ENV TZ "Europe/Paris"

WORKDIR /linky2db

COPY requirements.txt .

RUN --mount=type=cache,target=/root/.cache \
    pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt

COPY src .

CMD [ "python", "linky2db.py" ]