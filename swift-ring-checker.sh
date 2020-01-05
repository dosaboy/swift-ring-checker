#!/bin/bash -eu
# Author: Edward Hope-Morley (opentastic@gmail.com)
# Description: Swift Object Store Ring Checker Tool
# Copyright (C) 2017-2020 Edward Hope-Morley
#
# License:
#
# swift-ring-checker is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# swift-ring-checker is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with swift-ring-checker. If not, see <http://www.gnu.org/licenses/>.

RES="\033[0m"
F_GRN="\033[32m"
F_CYN="\033[36m"
F_YLW="\033[33m"

DEBUG=false
RESOURCE=
SERVER="\*"

cleanup ()
{
    :
}
#trap cleanup INT KILL

usage ()
{
cat << EOF
USAGE: swift-ring-checker OPTS RESOURCE

OPTS:
  -h|--help
    Print this help message.

RESOURCE:
  builders SERVER|rings SERVER|hash|relations

SERVER:
  account|container|object

EOF
}

(($#)) || { usage; exit 1; }
while (($#)); do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
	--debug)
            DEBUG=true
            ;;
        *)
            RESOURCE="$1"
	    if (($#>1)) && \
		    ( [ "$RESOURCE" = "builders" ] || [ "$RESOURCE" = "rings" ] ); then
		if [ "$2" = "account" ] || [ "$2" = "container" ] || [ "$2" = "object" ]; then
                    SERVER="$2"
                    shift
	        fi
            fi
            ;;
    esac
    shift
done

$DEBUG && set -x

juju --version

juju status

get_units ()
{
    local app="$1"

    # only return active units
    juju status --format=json $app| jq -r ".applications.\"$app\".units | to_entries[] | select(.value.\"workload-status\".current==\"unknown\" | not) | .key"
}

readarray -t PROXY_UNITS<<<"`get_units swift-proxy`"
declare -a STORAGE_UNITS=()
readarray -t _S<<<"`get_units swift-storage-z1`"
STORAGE_UNITS+=( ${_S[@]} )
readarray -t _S<<<"`get_units swift-storage-z2`"
STORAGE_UNITS+=( ${_S[@]} )
readarray -t _S<<<"`get_units swift-storage-z3`"
STORAGE_UNITS+=( ${_S[@]} )

check_ring ()
{
    local unit="$1"
    local ringgz="$2"

    # Display the ring md5sum in blue and display proxy service status
    juju ssh $unit \
            "echo -ne '${F_YLW}'; \
             sudo find /etc/swift/ -maxdepth 1 -name $ringgz| sort| xargs -l sudo md5sum; \
             echo -ne '${RES}'; \
             echo -n 'STATUS: '; \
             sudo systemctl status -n 0 swift-proxy --no-pager" 2>/dev/null
}

check_builder ()
{
    local unit="$1"
    local builder="$2"

    # Builder dev info
    juju ssh $unit \
            "sudo find /etc/swift/ -maxdepth 1 -name $builder| sort| xargs -l sudo swift-ring-builder; \
             echo -ne '${F_YLW}'; \
             sudo find /etc/swift/ -maxdepth 1 -name $builder| sort| xargs -l sudo md5sum; \
             echo -ne '${RES}'; \
             echo -n 'STATUS: '; \
             sudo systemctl status -n 0 swift-proxy --no-pager" 2>/dev/null
}

check_relations ()
{
        local p_unit="$1"

        # Display relation info
        for s_unit in ${STORAGE_UNITS[@]}; do
            echo -e "${F_YLW}= $s_unit${RES}"

            # storage from proxy
            readarray -t rids<<<"`juju run -u $s_unit 'relation-ids swift-storage'`"
            for rid in ${rids[@]}; do
                out="`juju run -u $s_unit 'relation-get -r $rid - $p_unit' 2>/dev/null`" || true
                if [ -n "$out" ]; then
                    echo -e "${F_CYN}= $s_unit <- $p_unit rid=$rid${RES}"
                    echo "$out"
                fi
            done

            # storage from storage
            for rid in ${rids[@]}; do
                out="`juju run -u $s_unit 'relation-get -r $rid - $s_unit' 2>/dev/null`" || true
                if [ -n "$out" ]; then
                    echo -e "${F_CYN}= $s_unit <- $s_unit rid=$rid${RES}"
                    echo "$out"
                fi
            done

            # proxy from storage
            readarray -t rids<<<"`juju run -u $p_unit 'relation-ids swift-storage'`"
            for rid in ${rids[@]}; do
                out="`juju run -u $p_unit 'relation-get -r $rid - $s_unit' 2>/dev/null`" || true
                if [ -n "$out" ]; then
                    echo -e "${F_CYN}= $p_unit <- $s_unit rid=$rid${RES}"
                    echo "$out"
                fi
            done
        done

        # proxy from proxy
        readarray -t rids<<<"`juju run -u $p_unit 'relation-ids cluster'`"
        for _p_unit in ${PROXY_UNITS[@]}; do
            for rid in ${rids[@]}; do
                out="`juju run -u $p_unit 'relation-get -r $rid - $_p_unit' 2>/dev/null`" || true
                if [ -n "$out" ]; then
                    echo -e "${F_CYN}= $p_unit <- $_p_unit rid=$rid${RES}"
                    echo "$out"
                fi
            done
        done
}

for p_unit in ${PROXY_UNITS[@]}; do
    echo -e "\n${F_GRN}== $p_unit${RES}"
    builder="${SERVER}.builder"
    ringgz="${SERVER}.ring.gz"

    if [ "$RESOURCE" = "rings" ]; then
        check_ring $p_unit $ringgz
    elif [ "$RESOURCE" = "builders" ]; then
        check_builder $p_unit $builder
    elif [ "$RESOURCE" = "hash" ]; then
        # Display proxy hash
        juju ssh $p_unit -- sudo grep swift_hash /etc/swift/swift.conf 2>/dev/null
    elif [ "$RESOURCE" = "relations" ]; then
        check_relations $p_unit
    else
        echo "ERROR: unknown resource '$RESOURCE'"
        usage
        exit 1
    fi
done

if [ "$RESOURCE" = "rings" ]; then
    for s_unit in ${STORAGE_UNITS[@]}; do
        ringgz="${SERVER}.ring.gz"
        echo -e "\n${F_GRN}== $s_unit${RES}"
        echo -ne "${F_YLW}"
        juju ssh $s_unit -- \
            "sudo find /etc/swift/ -maxdepth 1 -name $ringgz| sort| xargs -l sudo md5sum 2>/dev/null"
        echo -ne "${RES}"
    done
fi

echo "Done."
