# shellcheck shell=bash
# Redis driver: cache only. Projects separate their keys with a prefix (REDIS_PREFIX).
redis_create() { return 0; }
redis_is_empty() { return 0; }
redis_root_shell() { ce_exec_tty "$1" -- redis-cli; }
redis_shell() { ce_exec_tty "$1" -- redis-cli; }
