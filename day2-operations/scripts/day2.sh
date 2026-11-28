#!/usr/bin/env bash
# One day-2 operation under the production-scenario load (supafirehose + the drill writer).
#
#   scripts/day2.sh az-partition 1     # the primary's zone cut off from the rest of the VPC
#   scripts/day2.sh ng-upgrade 1       # rolling replacement of the primary's node group
#   scripts/day2.sh disk-full 1        # fill the primary's volume, then grow it (FILL_LEAVE_MB, DISK_HOLD, GROW_TO)
#   scripts/day2.sh mg-upgrade 1       # roll to new images (MG_IMAGE, PGCTLD_IMAGE, MULTIADMIN_WEB_IMAGE)
#   scripts/day2.sh switchover 1       # multigres cluster switch-primary
#
# Takes the same environment as ../production-scenario/scripts/scenario.sh (CONNS, WRITE_FOR,
# FAULT_AT, AZ_HOLD, TAG). Runs land in results/storm-<drill>-c<conns>-<n>/.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
drill="${1:?drill}"
n="${2:?run number}"
export SCENARIO_RESULTS="$here/results"
exec "$here/../production-scenario/scripts/scenario.sh" storm "$n" "$drill"
