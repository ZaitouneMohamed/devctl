# shellcheck shell=bash
# Qdrant driver: no databases or users to create; projects use collections.
qdrant_create() { return 0; }
qdrant_is_empty() { return 0; }
