.PHONY: deploy migrate logs ps

deploy:
	git fetch origin main
	git reset --hard origin/main
	docker compose --profile mqtt up -d --build --pull --force-recreate --remove-orphans
	@echo "Waiting for MySQL to be healthy..."
	@until docker exec mysql mysqladmin ping -h localhost -u root -p$$(docker exec mysql printenv MYSQL_ROOT_PASSWORD) --silent 2>/dev/null; do sleep 1; done
	$(MAKE) migrate
	docker image prune -af

migrate:
	docker exec mysql sh -c 'sh /docker-entrypoint-initdb.d/init-script.sh'

logs:
	docker compose --profile mqtt logs -f linky2db-mqtt

ps:
	docker compose --profile mqtt ps
