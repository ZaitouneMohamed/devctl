# shellcheck shell=bash
# MongoDB driver. Root work authenticates with the root user the container was created with.

mongodb__root() { # CONTAINER [mongosh args...] — JavaScript from stdin
  local c=$1
  shift
  ce_exec "$c" -- sh -c 'exec mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin "$@"' sh "$@"
}

mongodb_create() { # CONTAINER DB USER PASSWORD
  printf "const d = db.getSiblingDB('%s');
const roles = [{role: 'readWrite', db: '%s'}, {role: 'dbAdmin', db: '%s'}];
if (d.getUser('%s')) { d.updateUser('%s', {pwd: '%s', roles: roles}); }
else { d.createUser({user: '%s', pwd: '%s', roles: roles}); }\n" \
    "$2" "$2" "$2" "$3" "$3" "$4" "$3" "$4" | mongodb__root "$1"
}

mongodb_is_empty() { # CONTAINER DB
  local n
  n=$(printf "print(db.getSiblingDB('%s').getCollectionNames().length)\n" "$2" | mongodb__root "$1")
  [[ $n == 0 ]]
}

mongodb_shell() { # CONTAINER DB USER PASSWORD — password through the environment
  MONGO_PASSWORD=$4 ce_exec_tty --env MONGO_PASSWORD "$1" -- sh -c 'exec mongosh -u "$1" -p "$MONGO_PASSWORD" --authenticationDatabase "$2" "$2"' sh "$3" "$2"
}

mongodb_root_shell() {
  ce_exec_tty "$1" -- sh -c 'exec mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'
}

mongodb_dump() { # CONTAINER DB → archive on stdout
  ce_exec "$1" -- sh -c 'exec mongodump --quiet --archive -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --db "$1"' sh "$2"
}

mongodb_restore() { # CONTAINER DB ← archive on stdin (restored into DB, whatever its old name)
  ce_exec "$1" -- sh -c 'exec mongorestore --quiet --archive -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --nsFrom "*.*" --nsTo "$1.*"' sh "$2"
}
