# Запуск
cd tasks/sharding-repl-cache

docker compose down -v --remove-orphans
bash init.sh
bash check.sh

# Проверки
docker compose ps
curl http://localhost:8080/
curl http://localhost:8080/helloDoc/users