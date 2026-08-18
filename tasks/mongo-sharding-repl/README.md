# MongoDB Sharding + Replication

Решение задания 3: к шардированному MongoDB-кластеру добавлена репликация каждого шарда.

## Архитектура

Используются два шарда. Каждый шард — ReplicaSet из трёх MongoDB-инстансов:

```text
                         pymongo-api
                              |
                              v
                         mongos_router
                         /          \
                        /            \
                       v              v

               ReplicaSet shard1   ReplicaSet shard2
               -----------------   -----------------
               shard1-1            shard2-1
               shard1-2            shard2-2
               shard1-3            shard2-3
```

После выборов в каждом ReplicaSet одна нода становится `PRIMARY`, две остальные — `SECONDARY`.

База данных: `somedb`.

Коллекция: `helloDoc`.

Shard key:

```javascript
{name: "hashed"}
```

## Структура директории

В каталоге должен сохраниться `api_app` из скопированного проекта `mongo-sharding`:

```text
mongo-sharding-repl/
├── api_app/
│   ├── Dockerfile
│   └── ...
├── compose.yaml
├── init.sh
├── check.sh
└── README.md
```

## Сервисы

| Service | Назначение |
|---|---|
| `pymongo-api` | Приложение, порт `8080` |
| `mongos_router` | MongoDB router |
| `configSrv` | Config Server |
| `shard1-1` | Первая реплика shard1 |
| `shard1-2` | Вторая реплика shard1 |
| `shard1-3` | Третья реплика shard1 |
| `shard2-1` | Первая реплика shard2 |
| `shard2-2` | Вторая реплика shard2 |
| `shard2-3` | Третья реплика shard2 |

`pymongo-api` подключается к `mongos_router`, поэтому приложение не зависит от того, какая нода ReplicaSet является `PRIMARY`.

## Запуск

Перейдите в директорию:

```bash
cd tasks/mongo-sharding-repl
```

Для чистого запуска:

```bash
docker compose down -v --remove-orphans
```

Инициализация:

```bash
bash init.sh
```

Проверка:

```bash
bash check.sh
```

`init.sh` сам запускает сервисы в безопасном порядке и в конце собирает/поднимает `pymongo-api`.

## Что делает init.sh

1. Запускает `configSrv`.
2. Запускает три ноды `shard1`.
3. Запускает три ноды `shard2`.
4. Инициализирует ReplicaSet `config_server`.
5. Инициализирует ReplicaSet `shard1`.
6. Инициализирует ReplicaSet `shard2`.
7. Ждёт состояния `1 PRIMARY + 2 SECONDARY` для каждого шарда.
8. Запускает `mongos_router`.
9. Регистрирует оба ReplicaSet как шарды.
10. Включает sharding для `somedb`.
11. Шардирует `somedb.helloDoc` по `{name: "hashed"}`.
12. Создаёт не менее 1000 документов.
13. Проверяет, что документы есть на обоих шардах.
14. Собирает и запускает `pymongo-api`.

## Что проверяет check.sh

`check.sh` проверяет:

- два зарегистрированных shard-а;
- общее количество документов `>= 1000`;
- наличие документов на обоих shard-ах;
- по три реплики в `shard1` и `shard2`;
- состояние `1 PRIMARY + 2 SECONDARY`;
- `sh.status()`;
- ответ приложения через `http://localhost:8080/`, если установлен `curl`.

Пример успешной финальной проверки:

```text
OK: 2 shards registered
OK: total documents >= 1000
OK: documents exist on both shards
OK: shard1 has 3 replicas (1 PRIMARY + 2 SECONDARY)
OK: shard2 has 3 replicas (1 PRIMARY + 2 SECONDARY)
SUCCESS
```

## Повторный запуск

```bash
docker compose down -v --remove-orphans
bash init.sh
bash check.sh
```