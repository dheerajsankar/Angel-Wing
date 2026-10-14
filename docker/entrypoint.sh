#!/bin/bash
set -e

source /opt/ros/jazzy/setup.bash
if [ -f /workspaces/Angel-Wing/install/setup.bash ]; then
    source /workspaces/Angel-Wing/install/setup.bash
fi

exec "$@"
