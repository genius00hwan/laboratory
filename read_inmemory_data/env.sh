# Convenience helpers for this experiment directory.

export MYSQL="mysql -h 127.0.0.1 -P 3310 -u lab -plab read_inmemory_data -N -s"
export MYSQL_ROOT="mysql -h 127.0.0.1 -P 3310 -u root -proot read_inmemory_data -N -s"
export REDIS_CLI="redis-cli -h 127.0.0.1 -p 6381 --raw"

mysql_lab() {
  mysql -h 127.0.0.1 -P 3310 -u lab -plab read_inmemory_data -N -s "$@"
}

mysql_root_lab() {
  mysql -h 127.0.0.1 -P 3310 -u root -proot read_inmemory_data -N -s "$@"
}

redis_lab() {
  redis-cli -h 127.0.0.1 -p 6381 "$@"
}
