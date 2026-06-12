#!/bin/bash
echo
echo "update_tiles.sh run:" `date`
#
if ! command -v osm2pgsql-replication &> /dev/null
then
    echo "osm2pgsql-replication could not be found"
    exit 1
fi
#
if [[ -f /var/cache/renderd/update_tiles.sh.running ]]
then
    echo "update_tiles.sh already running; /var/cache/renderd/update_tiles.sh.running exists"
    exit 1
else
    touch /var/cache/renderd/update_tiles.sh.running
fi
#
if ! osm2pgsql-replication update -d gis --post-processing /usr/local/sbin/expire_tiles.sh --max-diff-size 20  -- -S /home/renderaccount/src/openstreetmap-carto/openstreetmap-carto-flex.lua -C 2500 --number-processes 4 --expire-tiles=1-20 --expire-output=/var/cache/renderd/dirty_tiles.txt > /var/cache/renderd/osm2pgsql-replication.$$ 2>&1
then
    echo "osm2pgsql-replication error"
    cat /var/cache/renderd/osm2pgsql-replication.$$
else
    grep Backlog /var/cache/renderd/osm2pgsql-replication.$$ | tail -1
    rm /var/cache/renderd/osm2pgsql-replication.$$
fi
#
rm /var/cache/renderd/update_tiles.sh.running
#
