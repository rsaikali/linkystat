#!/bin/bash -e

docker compose --env-file ../env/.env.dev stop --timeout 1 
docker compose --env-file ../env/.env.dev -f ../docker-compose.yaml -f ../docker-compose.dev.yaml up --build -d
