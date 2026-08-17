# Task 2 — MongoDB Sharding

Директория `mongo-sharding` содержит решение задания 2: MongoDB-кластер с двумя шардами.

Состав стенда:

- `pymongo-api` — приложение, доступно на порту `8080`;
- `mongos_router` — MongoDB Router, единая точка подключения приложения к кластеру;
- `configSrv` — Config Server;
- `shard1` — первый shard;
- `shard2` — второй shard;
- база данных — `somedb`;
- коллекция — `helloDoc`;
- shard key — `{ name: "hashed" }`.

## Запуск

```text
cd tasks/mongo-sharding
docker compose up -d
bash init.sh
```

Проверка:

```bash
bash check.sh
```

## Что делает init.sh

Скрипт выполняет те же шаги, которые можно выполнить вручную:

1. запускает `configSrv`, `shard1`, `shard2`;
2. инициализирует ReplicaSet `config_server`;
3. инициализирует ReplicaSet `shard1`;
4. инициализирует ReplicaSet `shard2`;
5. ждёт, пока все три инстанса станут `PRIMARY`;
6. запускает `mongos_router`;
7. добавляет `shard1` и `shard2` в кластер;
8. включает sharding для `somedb`;
9. включает hashed sharding коллекции `somedb.helloDoc` по полю `name`;
10. создаёт 1000 тестовых документов;
11. запускает `pymongo-api`.

## Ожидаемый результат

Команда:

```bash
bash check.sh
```

должна показать:

```text
Shard count: 2
Total: 1000
shard1: > 0
shard2: > 0
```