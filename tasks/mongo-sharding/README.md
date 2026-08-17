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

В задании 2 каждый shard содержит один MongoDB-инстанс. Репликация по три инстанса на shard будет добавлена в следующем задании.

## Требования

- Docker Desktop / Docker Engine;
- Docker Compose v2;
- минимум 2 CPU и 4 GB RAM.

## Быстрый запуск

Откройте терминал в директории:

```text
tasks/mongo-sharding
```

Запустите контейнеры:

```bash
docker compose up -d
```

После этого выполните инициализацию:

### Windows + VS Code + Git Bash

```bash
bash init.sh
```

`chmod +x` на Windows не требуется, если скрипт запускается через `bash init.sh`.

Проверка:

```bash
bash check.sh
```

### Linux / macOS / WSL

```bash
chmod +x init.sh check.sh
./init.sh
./check.sh
```

`init.sh` можно запускать повторно: уже созданные ReplicaSet и зарегистрированные shards повторно не создаются, а тестовые документы добавляются через upsert.

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

Количество документов на каждом shard не обязано быть ровно `500/500`. Важно, чтобы документы находились на обоих shards, а через `mongos_router` было видно не менее 1000 документов.

## Проверка API

После запуска:

```text
http://localhost:8080
```

Swagger:

```text
http://localhost:8080/docs
```

## Ручная инициализация в PowerShell

Этот раздел нужен для диагностики, если автоматический скрипт завершился с ошибкой.

### 1. Очистить старое состояние

Для полностью чистого запуска:

```powershell
docker compose down -v
docker compose up -d configSrv shard1 shard2
```

> `docker compose down -v` удаляет MongoDB volumes и все ранее созданные тестовые данные.

### 2. Config Server

```powershell
docker compose exec -T configSrv mongosh --port 27017 --quiet --eval "rs.initiate({_id:'config_server',configsvr:true,members:[{_id:0,host:'configSrv:27017'}]})"
```

Проверка:

```powershell
docker compose exec -T configSrv mongosh --port 27017 --quiet --eval "rs.status().members.map(x => ({name:x.name,stateStr:x.stateStr}))"
```

Ожидается `PRIMARY`.

### 3. Первый shard

```powershell
docker compose exec -T shard1 mongosh --port 27018 --quiet --eval "rs.initiate({_id:'shard1',members:[{_id:0,host:'shard1:27018'}]})"
```

Проверка:

```powershell
docker compose exec -T shard1 mongosh --port 27018 --quiet --eval "rs.status().members.map(x => ({name:x.name,stateStr:x.stateStr}))"
```

### 4. Второй shard

```powershell
docker compose exec -T shard2 mongosh --port 27019 --quiet --eval "rs.initiate({_id:'shard2',members:[{_id:0,host:'shard2:27019'}]})"
```

Проверка:

```powershell
docker compose exec -T shard2 mongosh --port 27019 --quiet --eval "rs.status().members.map(x => ({name:x.name,stateStr:x.stateStr}))"
```

Перед следующим шагом `configSrv`, `shard1` и `shard2` должны иметь состояние `PRIMARY`.

### 5. Запустить mongos

```powershell
docker compose up -d mongos_router
```

### 6. Добавить shards

```powershell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval "sh.addShard('shard1/shard1:27018')"
```

```powershell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval "sh.addShard('shard2/shard2:27019')"
```

Проверка:

```powershell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval "sh.status()"
```

В разделе `shards` должны присутствовать `shard1` и `shard2`.

### 7. Включить sharding

```powershell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval "sh.enableSharding('somedb')"
```

```powershell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval "sh.shardCollection('somedb.helloDoc',{name:'hashed'})"
```

### 8. Добавить тестовые документы

```powershell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval "let d=db.getSiblingDB('somedb'); let docs=[]; for(let i=0;i<1000;i++){docs.push({age:i,name:'ly'+i})}; d.helloDoc.insertMany(docs); print(d.helloDoc.countDocuments())"
```

Ожидаемый результат:

```text
1000
```

### 9. Проверить распределение

Общее количество:

```powershell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
```

Первый shard:

```powershell
docker compose exec -T shard1 mongosh --port 27018 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
```

Второй shard:

```powershell
docker compose exec -T shard2 mongosh --port 27019 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()"
```

## Повторный запуск с чистого состояния

```bash
docker compose down -v
docker compose up -d
bash init.sh
bash check.sh
```

## Остановка

Без удаления данных:

```bash
docker compose down
```

С удалением данных:

```bash
docker compose down -v
```

## Схема взаимодействия

```text
pymongo-api
     |
     v
mongos_router
   /   |    \
  v    v     v
shard1 configSrv shard2
```

Приложение работает с MongoDB через `mongos_router`. Router использует метаданные Config Server и направляет запросы в нужный shard.
