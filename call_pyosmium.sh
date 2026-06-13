#!/bin/bash
#
# call_pyosmium.sh
#
# Designed to be run from cron, as the user that owns the database (normally "_renderd").
# Note that "render_expired" doesn't use TILEDIR from map name in /etc/renderd.conf
# when deciding if tiles exist already; it assumes they must be below /var/cache .
# It therefore makes sense to use /var/cache/renderd/pyosmium for the files needed here.
#
# First, define the local user account we are using.
# "local_filesystem_user" is whichever non-root account is used to fetch from
# github.
#
local_filesystem_user=renderaccount
#
# To initialise "sequence.state", run:
#
# sudo mkdir /var/cache/renderd/pyosmium
# sudo chown _renderd /var/cache/renderd/pyosmium
# cd /var/cache/renderd/pyosmium
# sudo -u _renderd pyosmium-get-changes -D 2022-06-08T20:21:25Z -f sequence.state -v
#
# with an appropriate date.
#
if [[ ! -f /var/cache/renderd/pyosmium/sequence.state ]]
then
    echo "/var/cache/renderd/pyosmium/sequence.state does not exist"
    exit 1
fi
#
if ! command -v pyosmium-get-changes &> /dev/null
then
    echo "pyosmium-get-changes could not be found"
    exit 1
fi
#
if ! command -v osm2pgsql &> /dev/null
then
    echo "osm2pgsql could not be found"
    exit 1
fi
#
if ! command -v render_expired &> /dev/null
then
    echo "render_expired could not be found"
    exit 1
fi
#
if [[ -f /var/cache/renderd/pyosmium/call_pyosmium.running ]]
then
    echo "call_pyosmium alreadying running; /var/cache/renderd/pyosmium/call_pyosmium.running exists"
    exit 1
else
    touch /var/cache/renderd/pyosmium/call_pyosmium.running
fi
#
echo
echo "Pyosmium update started: " `date`
#
cd /var/cache/renderd/pyosmium/
rm newchange.osc.gz > pyosmium.$$ 2>&1
cp sequence.state sequence.state.old
#------------------------------------------------------------------------------
# "-s 20" here means "get 20MB at once".  
# The value can be adjusted up or down as needed.
#------------------------------------------------------------------------------
#
pyosmium-get-changes -f sequence.state -o newchange.osc.gz -s 20 >> pyosmium.$$ 2>&1
#
#------------------------------------------------------------------------------
# Trim the downloaded changes to only the ones that apply to our region.
#
# When using trim_osc.py we can define either a bounding box (such as this
# example for England and Wales) or a polygon.
# See https://github.com/zverik/regional .
# This area will usually correspond to the data originally loaded.
#------------------------------------------------------------------------------
TRIM_BIN=/home/${local_filesystem_user}/src/regional/trim_osc.py
TRIM_REGION_OPTIONS="-b -14.17 48.85 2.12 61.27"
#TRIM_REGION_OPTIONS="-p region.poly"

if [[ -f $TRIM_BIN ]]
then
    echo "Filtering newchange.osc.gz"
    if ! $TRIM_BIN -d gis $TRIM_REGION_OPTIONS  -z newchange.osc.gz newchange.osc.gz > trim.$$ 2>&1
    then
        echo "Trim_osc error but continue anyway"
    fi
else
    echo "${TRIM_BIN} does not exist but continue anyway"
fi
#
#------------------------------------------------------------------------------
# The osm2pgsql append line will need to be tailored to match the running system (memory and number of processors), the style in use, and
# the number of zoom levels to write dirty tiles for.
#------------------------------------------------------------------------------
echo "Importing newchange.osc.gz"
if ! osm2pgsql --append --slim -d gis -C 2500 --number-processes 2 --multi-geometry --tag-transform-script /home/${local_filesystem_user}/src/openstreetmap-carto/openstreetmap-carto.lua -S /home/${local_filesystem_user}/src/openstreetmap-carto/openstreetmap-carto.style --expire-tiles=1-20 --expire-output=/var/cache/renderd/pyosmium/dirty_tiles.txt /var/cache/renderd/pyosmium/newchange.osc.gz > osm2pgsql.$$ 2>&1
then
    # ------------------------------------------------------------------------------
    # The osm2pgsql import failed; show the error, revert to the previous import
    # sequence and remove the "running" flag to try again.
    # Don't delete the command output files to allow later investigation.
    # ------------------------------------------------------------------------------
    echo "osm2pgsql append error"
    cat osm2pgsql.$$
    cp sequence.state.old sequence.state
    rm /var/cache/renderd/pyosmium/call_pyosmium.running
    exit 1
else
    tail -1 osm2pgsql.$$
fi
#
#------------------------------------------------------------------------------
# This line is exactly the same as the "expire_tiles.sh"
# that would be used with "update_tiles.sh" (which calls "osm2pgsql-replication update" rather than the more flexible "pyosmium-get-changes")
# The arguments can be tailored to do different things at different zoom levels as desired.
#------------------------------------------------------------------------------
echo "Expiring tiles"
render_expired --map=s2o --min-zoom=13 --touch-from=13 --delete-from=19 --max-zoom=20 -s /run/renderd/renderd.sock < /var/cache/renderd/pyosmium/dirty_tiles.txt > render_expired.$$ 2>&1
tail -9 render_expired.$$
#
#------------------------------------------------------------------------------
# If debugging tile dirtying, comment out these two lines and uncomment the third.
#------------------------------------------------------------------------------
rm /var/cache/renderd/pyosmium/dirty_tiles.txt >> pyosmium.$$ 2>&1
rm render_expired.$$
#mv /var/cache/renderd/pyosmium/dirty_tiles.txt /var/cache/renderd/pyosmium/dirty_tiles.txt.$$ >> pyosmium.$$ 2>&1
#
#------------------------------------------------------------------------------
# Tidy up files containing output from each command and the file that shows
# that the script is running
#------------------------------------------------------------------------------
rm trim.$$
rm osm2pgsql.$$
rm pyosmium.$$
rm /var/cache/renderd/pyosmium/call_pyosmium.running
#
echo "Database Replication Lag:" `/usr/local/sbin/pyosmium_replag.sh -h`
#
