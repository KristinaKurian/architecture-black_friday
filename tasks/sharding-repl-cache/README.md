## Архитектура

```text
                           +---------+
                           |  Redis  |
                           +----^----+
                                |
                                |
                         +------+------+
                         | pymongo-api |
                         +------+------+
                                |
                                v
                         +------+------+
                         | mongos_router|
                         +------+------+
                            /       \
                           /         \
                          v           v

                  ReplicaSet       ReplicaSet
                    shard1           shard2
                  -----------      -----------
                  shard1-1         shard2-1
                  shard1-2         shard2-2
                  shard1-3         shard2-3
```
## Redis

```yaml
REDIS_URL: "redis://redis:6379"
```

Кеширование приложения проверяется на эндпоинте:

```text
/helloDoc/users
```

## Запуск

```bash
docker compose down -v --remove-orphans
bash init.sh
bash check.sh
```

`init.sh` автоматически:

1. запускает Redis;
2. запускает Config Server;
3. запускает по три MongoDB-инстанса для каждого shard;
4. инициализирует ReplicaSet `config_server`;
5. инициализирует ReplicaSet `shard1` и `shard2`;
6. ждёт состояния `1 PRIMARY + 2 SECONDARY`;
7. запускает `mongos_router`;
8. регистрирует два shard-а;
9. включает sharding для `somedb`;
10. шардирует `somedb.helloDoc` по `{name: "hashed"}`;
11. создаёт не менее 1000 документов;
12. запускает `pymongo-api` с `REDIS_URL=redis://redis:6379`.

## Проверка кеширования

Первый запрос прогревает кеш:

```bash
curl -o /dev/null -s -w "first: %{time_total}s\n" \
  http://localhost:8080/helloDoc/users
```

Второй запрос:

```bash
curl -o /dev/null -s -w "second: %{time_total}s\n" \
  http://localhost:8080/helloDoc/users
```

Третий запрос:

```bash
curl -o /dev/null -s -w "third: %{time_total}s\n" \
  http://localhost:8080/helloDoc/users
```

По условию задания второй и последующие запросы должны выполняться быстрее `0.100` секунды.

`check.sh` автоматизирует эту проверку: первый вызов прогревает кеш, затем измеряются второй и третий вызовы.

Посмотреть количество ключей в Redis после запросов:

```bash
docker compose exec -T redis redis-cli DBSIZE
```

## Что проверяет check.sh

- Redis отвечает `PONG`;
- зарегистрировано два shard-а;
- общее число документов `>= 1000`;
- документы присутствуют на обоих shard-ах;
- в каждом shard по три реплики;
- состояния реплик — `1 PRIMARY + 2 SECONDARY`;
- второй и третий запросы `/helloDoc/users` выполняются `<100 ms`.

Успешный результат заканчивается примерно так:

```text
OK: Redis is available
OK: 2 shards registered
OK: total documents >= 1000
OK: documents exist on both shards
OK: shard1 has 3 replicas (1 PRIMARY + 2 SECONDARY)
OK: shard2 has 3 replicas (1 PRIMARY + 2 SECONDARY)
OK: cached requests are < 100 ms
SUCCESS
```

## Полный сброс

```bash
docker compose down -v --remove-orphans
bash init.sh
bash check.sh
```
