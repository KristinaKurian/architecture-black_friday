# Task 2 — MongoDB Sharding

Директория `mongo-sharding` реализует первый вариант архитектуры из задания 1:

- `pymongo-api` — приложение, порт `8080`;
- `mongos_router` — единая точка входа приложения в MongoDB;
- `configSrv` — MongoDB Config Server;
- `shard1` и `shard2` — два MongoDB shard;
- база `somedb`;
- коллекция `helloDoc`;
- shard key `{ name: "hashed" }`.

## 1. Запуск

```bash
docker compose up -d
```

## 2. Инициализация MongoDB sharding

```bash
chmod +x init.sh check.sh
./init.sh
```

Скрипт:

1. инициализирует ReplicaSet `config_server`;
2. инициализирует `shard1`;
3. инициализирует `shard2`;
4. добавляет оба shard в `mongos_router`;
5. включает sharding для `somedb`;
6. включает hashed sharding коллекции `somedb.helloDoc` по полю `name`;
7. создаёт не менее 1000 тестовых документов (повторный запуск не создаёт дубликаты по `_id`).

## 3. Проверка

```bash
./check.sh
```

Скрипт выводит:

- состояние контейнеров;
- общее количество документов через `mongos_router`;
- количество документов на `shard1`;
- количество документов на `shard2`;
- `sh.status()`.

## 4. Проверка вручную

Общее количество:

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF
```

Первый shard:

```bash
docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF
```

Второй shard:

```bash
docker compose exec -T shard2 mongosh --port 27019 --quiet <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF
```

Статус sharding:

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval 'sh.status()'
```

## 5. API

После запуска приложение должно быть доступно по адресу:

```text
http://localhost:8080
```

Swagger / OpenAPI:

```text
http://localhost:8080/docs
```

## 6. Остановка

```bash
docker compose down
```

Удалить стенд вместе с volumes и начать с чистой MongoDB:

```bash
docker compose down -v
```

После этого снова выполните:

```bash
docker compose up -d
./init.sh
```

## Схема взаимодействия

Приложение не подключается к shard напрямую. Запросы идут в `mongos_router`, который использует metadata Config Server и маршрутизирует операции на нужный shard.
