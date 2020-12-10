#!/bin/bash 

#	--------------------------------------------------------------------------
#	name		dellFanSpeedRegulation.sh
#	Description	Dell fan control mitigation.
#				This script will maitain the fan speed at the minimum possible
#				while keeping your system under the temp you specify.
#   Tested on 	Dell R420 with Proxmox
#	
# 	History:
#   #######
#	2019-07-19 - iNet uka      - Creation (Original author, all rights remain)
#	2020-12-07 - Gael Langlais - Add the deamon from Ref: https://unix.stackexchange.com/questions/426862/proper-way-to-run-shell-script-as-a-daemon (LSerni post)
#
#	This file is public domain and provided as-is.
#	There are NO guarantees. Use at your own risk.
#
#	--------------------------------------------------------------------------

if [ "$1" = "DAEMON" ]; then
    # is this necessary? Add other signals at will (TTIN TTOU INT STOP TSTP)
    trap '' INT
    cd /tmp
    shift

    # minimum rpm in % that cannot be gone below, even if the system is ever so cool
	MIN_RPM=5

	# maximum rpm in % that never can be exceeded
	MAX_RPM=100

	# target temp of the system that should not be exceeded even at maximum load
	# actually this builds a range with RAMP_TMP (AVG_TMP +- RAMP_TMP)
	# if the range is exceeded at max rpm an alarm is sent
	AVG_TMP=40

	# temp diff that enforces a reaction in fan rpm
	RAMP_TMP=1

	# rpm diff in % per reaction
	RAMP_RPM=1

	# check temps every ... seconds
	LOOPTIME=20

	RETVAL=""

	MYHOST=$(hostname)
	MYDOMAIN=example.com

	MYLOG=/var/log/ipmi-fan.log
	MYLOCK=/var/run/ipmi-fan.lck
	MYSENS=/tmp/core.sense

	#
	## functions #################################################################################
	#
	log_message()
	{
		timestamp=$(date +%F-%H-%M-%S)
		echo "$timestamp $1" >> $MYLOG
	}

	get_system_temp()
	{
	    act_tmp=0
	    num_cores=${#cores[@]}

	    for val_dec in "${cores[@]}"
	    do
	        act_tmp=$(($act_tmp+$val_dec))
	    done
	    
	    # Prevent division by zero error
	    if [ $num_cores -lt 1 ]; then num_cores=1; fi
	    # get the mean temp value from all cores
	    act_tmp=$(($act_tmp/$num_cores))
	}

	set_fan_rpm()
	{
	    act_rpm=$1

	    if [ $act_rpm -gt $MAX_RPM ]; then act_rpm=$MAX_RPM; fi
	    if [ $act_rpm -lt $MIN_RPM ]; then act_rpm=$MIN_RPM; fi

	    dec_to_hex $act_rpm; act_rpm_hex=$RETVAL; RETVAL=""

	    log_message "INFO  -- Temp $act_tmp, Set RPM to 0x$act_rpm_hex ($act_rpm%)"

	    ipmitool raw 0x30 0x30 0x02 0xff 0x$act_rpm_hex >/dev/null 2>&1
	}

	alert_fan_rpm()
	{
	    if [ $cnt_alert -eq 0 ]; then

	        mail -s "Temperature Alert $MYHOST ($1)" -a"From:$MYHOST \<$MYHOST@$MYDOMAIN\>" root < $MYSENS
	        log_message "ERROR -- Temperature too high at 100% fan rpm. Sending alert."

	    fi
	    
	    # only on first occasion and then after $LOOPTIME rounds an alert is generated. if LOOPTIME is set to 30
	    # the alert is repeated after 30x30 seconds (15min)
	    cnt_alert=$(($cnt_alert+1)); if [ $cnt_alert -eq $LOOPTIME ]; then cnt_alert=0; fi
	}

	dec_to_hex()
	{
	    val_hex=( $(echo "obase=16; ibase=10; $1" | bc) )
	    val_dec=( $(echo "obase=10; ibase=16; $val_hex" | bc) )

	    if [ $1 -ne $val_dec ]; then

	        log_message "ERROR -- Value conversion error, aborting."
	        exit 1

	    fi

	    RETVAL=$val_hex
	}

	get_abs()
	{
	    val_dec=$1
	    RETVAL=${val_dec#-}
	}

	#
	## main ##########################################################################################
	#

	command -v bc >/dev/null 2>&1       || { echo "bc program required but not found, aborting."; exit 1; }
	command -v mail >/dev/null 2>&1     || { echo "mail program required but not found, aborting."; exit 1; }
	command -v sensors >/dev/null 2>&1  || { echo "sensors program required but not found, aborting."; exit 1; }
	command -v ipmitool >/dev/null 2>&1 || { echo "ipmitool program required but not found, aborting."; exit 1; }

	if [ -f "$MYLOCK" ]; then

	    log_message "ERROR -- ipmi-fan may be called only once, aborting. $MYLOCK?"
	    #exit 2

	fi

	touch "$MYLOCK"

	act_tmp=0
	act_rpm=0
	act_rpm_hex=0
	val_dec=0
	val_hex=0
	num_cores=0
	cnt_alert=0

	# set fan rpm control to manual
	ipmitool raw 0x30 0x30 0x01 0x00 >/dev/null 2>&1

	sensors | grep Core > $MYSENS

	get_system_temp
	set_fan_rpm $MAX_RPM
	sleep 5

	get_system_temp
	set_fan_rpm $MIN_RPM
	sleep $LOOPTIME

    ### daemonized section ######
    while true; do
    	sensors | grep Core > $MYSENS

	    # cut string at +-sign, second element starts with temperature, cut at .-sign, first element is temperature
	    cores=( $(cut -d'+' -f2 $MYSENS | cut -d'.' -f1) )

	    get_system_temp

	    # only if temp diff is larger than RAMP_TMP do something
	    delta_t=$(($act_tmp-$AVG_TMP))
	    get_abs $delta_t

	    if [ $RETVAL -ge $RAMP_TMP ]; then

	        # the system is at least RAMP_TMP hotter than it should be
	        if [ $delta_t -gt 0 ]; then

	            # if already max fan rpm
	            if [ $act_rpm -eq $MAX_RPM ]; then

	                alert_fan_rpm $delta_t

	            fi

	            # we are not at the upper border yet
	            if [ $act_rpm -lt $MAX_RPM ]; then

					echo "#INFO - Actual Temp: $act_tmp C°, Target Temp: $AVG_TMP C°"
					echo "#INFO - We are $delta_t C° above target. Increasing fan Speed by 1%."
	                set_fan_rpm $(($act_rpm+$RAMP_RPM))

	            fi


	        fi

	        # the system is at least RAMP_TMP cooler than expected
	        if [ $delta_t -lt 0 ]; then

	            # if not already at the lower border
	            if [ $act_rpm -gt $MIN_RPM ]; then

					echo "#INFO - Actual Temp: $act_tmp C°, Target Temp: $AVG_TMP C°"
					echo "#INFO - All good, we are at $delta_t C° below target. Reducing fan Speed by 1%."
	                set_fan_rpm $(($act_rpm-$RAMP_RPM))

	            fi

	        fi

	    fi

	    sleep $LOOPTIME

    done
    #### end of daemonized section ####
    exit 0
fi

export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin
umask 022
# You can add nice and ionice before nohup but they might not be installed
nohup setsid $0 DAEMON $* 2>/var/log/mydaemon.err >/var/log/mydaemon.log &


# eof
