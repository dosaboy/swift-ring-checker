#!/bin/bash -eu
# Author: Edward Hope-Morley (opentastic@gmail.com)
# Description: Swift Object Store Ring Checker Tool
# Copyright (C) 2017-2018 Edward Hope-Morley
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

trap 'exit' SIGINT SIGKILL

usage ()
{
    echo "USAGE: `basename $0` <resource>"
    echo ""
    echo "RESOURCE:"
    echo "    [builders SERVER]|[rings SERVER]|hash|relations"
    echo ""
    echo "SERVER:"
    echo "    account|container|object"
    echo ""
    echo ""
    echo "ENV VARS:"
    echo ""
    echo "  JUJU_V1 - set this to use with Juju 1.x"
    echo ""
    echo ""
}

(($#)) || { usage; exit 1; }
for arg in $@; do if [ $arg = "-h" ]; then { usage; exit 1; }; fi; done


#!/bin/bash -eu
get_units ()
{
cat <<- EOF| python - $1
import json, subprocess, sys, os
data = subprocess.check_output(['juju', 'status', '--format=json'])
j = json.loads(data)
if os.environ.get('JUJU_V1'):
    applications = j['services']
else:
    applications = j['applications']

proxies = []
for key in applications:
    charm = applications[key]['charm']
    if 'swift-proxy' in charm:
        units = applications[key]['units'].keys()
        proxies+=units
stores = []
for key in applications:
    charm = applications[key]['charm']
    if 'swift-storage' in charm:
        units = applications[key]['units'].keys()
        stores+=units
if len(sys.argv) > 1 and sys.argv[1] == 'proxy':
    print '\n'.join(sorted(proxies))
else:
    print '\n'.join(sorted(stores))

EOF
}

read -a PROXY_UNITS<<<`get_units proxy`
read -a STORAGE_UNITS<<<`get_units store`

for p_unit in ${PROXY_UNITS[@]}; do
    echo -e "\n${F_GRN}== $p_unit${RES}"
    if (($#>1)); then
        builder="$2.builder"
        ringgz="$2.ring.gz"
    else
        builder="\*.builder"
        ringgz="\*.ring.gz"
    fi

    if [ "$1" = "rings" ]; then
        # Display the ring md5sum in blue and display proxy service status
        juju ssh $p_unit \
                "echo -ne '${F_YLW}'; \
                 sudo find /etc/swift/ -maxdepth 1 -name $ringgz| sort| xargs -l sudo md5sum; \
                 echo -ne '${RES}'; \
                 echo -n 'STATUS: '; \
                 sudo systemctl status -n 0 swift-proxy --no-pager 2>/dev/null || sudo service swift-proxy status || true" 2>/dev/null
    elif [ "$1" = "builders" ]; then
        # Builder dev info
        juju ssh $p_unit \
                "sudo find /etc/swift/ -maxdepth 1 -name $builder| sort| xargs -l sudo swift-ring-builder; \
                 echo -ne '${F_YLW}'; \
                 sudo find /etc/swift/ -maxdepth 1 -name $builder| sort| xargs -l sudo md5sum; \
                 echo -ne '${RES}'; \
                 echo -n 'STATUS: '; \
                 sudo systemctl status -n 0 swift-proxy --no-pager 2>/dev/null || sudo service swift-proxy status || true" 2>/dev/null
    elif [ "$1" = "hash" ]; then
        # Display proxy hash
        juju ssh $p_unit 'sudo grep swift_hash /etc/swift/swift.conf' 2>/dev/null
    elif [ "$1" = "relations" ]; then
        # Display relation info
        for s_unit in ${STORAGE_UNITS[@]}; do
            echo -e "${F_YLW}= $s_unit${RES}"

            # storage from proxy
            read -a rids<<<`juju run --unit $s_unit "relation-ids swift-storage"`
            for rid in ${rids[@]}; do
                out=`juju run --unit $s_unit "relation-get -r $rid - $p_unit" 2>/dev/null` || true
                if [ -n "$out" ]; then
                    echo -e "${F_CYN}= $s_unit <- $p_unit rid=$rid${RES}"
                    echo "$out"
                fi
            done

            # storage from storage
            for rid in ${rids[@]}; do
                out=`juju run --unit $s_unit "relation-get -r $rid - $s_unit" 2>/dev/null` || true
                if [ -n "$out" ]; then
                    echo -e "${F_CYN}= $s_unit <- $s_unit rid=$rid${RES}"
                    echo "$out"
                fi
            done

            # proxy from storage
            read -a rids<<<`juju run --unit $p_unit "relation-ids swift-storage"`
            for rid in ${rids[@]}; do
                out=`juju run --unit $p_unit "relation-get -r $rid - $s_unit" 2>/dev/null` || true
                if [ -n "$out" ]; then
                    echo -e "${F_CYN}= $p_unit <- $s_unit rid=$rid${RES}"
                    echo "$out"
                fi
            done
        done

        # proxy from proxy
        read -a rids<<<`juju run --unit $p_unit "relation-ids cluster"`
        for _p_unit in ${PROXY_UNITS[@]}; do
            for rid in ${rids[@]}; do
                out=`juju run --unit $p_unit "relation-get -r $rid - $_p_unit" 2>/dev/null` || true
                if [ -n "$out" ]; then
                    echo -e "${F_CYN}= $p_unit <- $_p_unit rid=$rid${RES}"
                    echo "$out"
                fi
            done
        done
    else
        echo "ERROR: unknown action '$1'"
        usage
        exit 1
    fi
done

for s_unit in ${STORAGE_UNITS[@]}; do
    if (($#>1)); then
        ringgz="$2.ring.gz"
    else
        ringgz="\*.ring.gz"
    fi

    if [ "$1" = "rings" ]; then
        echo -e "\n${F_GRN}== $s_unit${RES}"
        echo -ne "${F_YLW}"
        juju ssh $s_unit \
            "sudo find /etc/swift/ -maxdepth 1 -name $ringgz| sort| xargs -l sudo md5sum" 2>/dev/null
        echo -ne "${RES}"
    fi
done
