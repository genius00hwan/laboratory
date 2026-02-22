# Convenience for running the SQL files in this repo.
# NOTE: this file is meant to be sourced from interactive shells (zsh/bash),
# so do not enable strict shell options like `set -u` here.
#
# MySQL 접속(요청한 기준): -h 127.0.0.1 -P 3307 -u lab -plab isolation_lab
export MYSQL="mysql -h 127.0.0.1 -P 3307 -u lab -plab isolation_lab -N -s"

# Root connection (for performance_schema access / GRANT)
export MYSQL_ROOT="mysql -h 127.0.0.1 -P 3307 -u root -proot isolation_lab -N -s"

# In zsh, `$MYSQL < file.sql` won't work unless you enable word-splitting.
# Use these functions for interactive shells:
mysql_lab() {
  mysql -h 127.0.0.1 -P 3307 -u lab -plab isolation_lab -N -s "$@"
}

mysql_root_lab() {
  mysql -h 127.0.0.1 -P 3307 -u root -proot isolation_lab -N -s "$@"
}
