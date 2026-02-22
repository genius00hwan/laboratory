-- Grant minimal read access for performance_schema metrics to lab user.
-- Run as root (see env.sh MYSQL_ROOT).

GRANT SELECT ON performance_schema.* TO 'lab'@'%';
GRANT SELECT ON sys.* TO 'lab'@'%';
FLUSH PRIVILEGES;

