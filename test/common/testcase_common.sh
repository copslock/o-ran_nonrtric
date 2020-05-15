#!/bin/bash

#  ============LICENSE_START===============================================
#  Copyright (C) 2020 Nordix Foundation. All rights reserved.
#  ========================================================================
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#  ============LICENSE_END=================================================
#

# This is a script that contains all the functions needed for auto test
# Arg: local|remote|remote-remove [auto-clean]


#Formatting for 'echo' cmd
BOLD="\033[1m"
EBOLD="\033[0m"
RED="\033[31m\033[1m"
ERED="\033[0m"
GREEN="\033[32m\033[1m"
EGREEN="\033[0m"
YELLOW="\033[33m\033[1m"
EYELLOW="\033[0m"
SAMELINE="\033[0K\r"

tmp=$(which python3)
if [ $? -ne 0 ] || [ -z tmp ]; then
	echo -e $RED"python3 is required to run the test environment, pls install"$ERED
	exit 1
fi
tmp=$(which docker)
if [ $? -ne 0 ] || [ -z tmp ]; then
	echo -e $RED"docker is required to run the test environment, pls install"$ERED
	exit 1
fi

# Just resetting any previous echo formatting...
echo -ne $EBOLD

# source test environment variables
. ../common/test_env.sh

echo "Test case started as: ${BASH_SOURCE[$i+1]} "$@

#Vars for A1 interface version and container count
G1_A1_VERSION=""
G2_A1_VERSION=""
G3_A1_VERSION=""
G1_COUNT=0
G2_COUNT=0
G3_COUNT=0

# Vars to switch between http and https. Extra curl flag needed for https
export RIC_SIM_HTTPX="http"
export RIC_SIM_LOCALHOST=$RIC_SIM_HTTPX"://localhost:"
export RIC_SIM_PORT=$RIC_SIM_INTERNAL_PORT
export RIC_SIM_CERT_MOUNT_DIR="./cert"

export MR_HTTPX="http"
export MR_PORT=$MR_INTERNAL_PORT
export MR_LOCAL_PORT=$MR_EXTERNAL_PORT #When agent is running outside the docker net

export SDNC_HTTPX="http"
export SDNC_PORT=$SDNC_INTERNAL_PORT
export SDNC_LOCAL_PORT=$SDNC_EXTERNAL_PORT #When agent is running outside the docker net

#Localhost constant
LOCALHOST="http://localhost:"

# Make curl retries for http response codes set in this env var, space separated list of codes
AGENT_RETRY_CODES=""

# Var to contol if the agent runs in a container (normal = 0) or as application on the local machine ( = 1)
AGENT_STAND_ALONE=0

# Var to hold 'auto' in case containers shall be stopped when test case ends
AUTO_CLEAN=""

# Set a description string for the test case
if [ -z "$TC_ONELINE_DESCR" ]; then
	TC_ONELINE_DESCR="<no-description>"
	echo "No test case description found, TC_ONELINE_DESCR should be set on in the test script , using "$TC_ONELINE_DESCR
fi

# Counter for test suites
if [ -f .tmp_tcsuite_ctr ]; then
	tmpval=$(< .tmp_tcsuite_ctr)
	((tmpval++))
	echo $tmpval > .tmp_tcsuite_ctr
fi

# Create a test case id, ATC (Auto Test Case), from the name of the test case script.
# FTC1.sh -> ATC == FTC1
ATC=$(basename "${BASH_SOURCE[$i+1]}" .sh)

# Create the logs dir if not already created in the current dir
if [ ! -d "logs" ]; then
    mkdir logs
fi
TESTLOGS=$PWD/logs

# Create a http message log for this testcase
HTTPLOG=$PWD"/.httplog_"$ATC".txt"
echo "" > $HTTPLOG

# Create a log dir for the test case
mkdir -p $TESTLOGS/$ATC

# Clear the log dir for the test case
rm $TESTLOGS/$ATC/*.log &> /dev/null
rm $TESTLOGS/$ATC/*.txt &> /dev/null
rm $TESTLOGS/$ATC/*.json &> /dev/null

# Log all output from the test case to a TC log
TCLOG=$TESTLOGS/$ATC/TC.log
exec &>  >(tee ${TCLOG})

#Variables for counting tests as well as passed and failed tests
RES_TEST=0
RES_PASS=0
RES_FAIL=0
RES_CONF_FAIL=0
RES_DEVIATION=0

#File to keep deviation messages
DEVIATION_FILE=".tmp_deviations"
rm $DEVIATION_FILE &> /dev/null

#Var for measuring execution time
TCTEST_START=$SECONDS

#File to save timer measurement results
TIMER_MEASUREMENTS=".timer_measurement.txt"
echo -e "Activity \t Duration" > $TIMER_MEASUREMENTS


echo "-------------------------------------------------------------------------------------------------"
echo "-----------------------------------      Test case: "$ATC
echo "-----------------------------------      Started:   "$(date)
echo "-------------------------------------------------------------------------------------------------"
echo "-- Description: "$TC_ONELINE_DESCR
echo "-------------------------------------------------------------------------------------------------"
echo "-----------------------------------      Test case setup      -----------------------------------"

echo -e $BOLD"Checking configured image setting for this test case"$EBOLD

#Temp var to check for image variable name errors
IMAGE_ERR=0
#Create a file with image info for later printing as a table
image_list_file=".image-list"
echo -e " Container\tImage\ttag" > $image_list_file

# Check if image env var is set and if so export the env var with image to use (used by docker compose files)
# arg: <image name> <script start-arg> <target-variable-name> <image-variable-name> <image-tag-variable-name>
__check_image_var() {
	if [ $# -ne 5 ]; then
		echo "Expected arg: <image name> <script start-arg> <target-variable-name> <image-variable-name> <image-tag-variable-name>"
		((IMAGE_ERR++))
		return
	fi
	tmp=${1}"\t"
	#Create var from the input var names
	image="${!4}"
	tag="${!5}"

	if [ -z $image ]; then
	 	echo -e $RED"\$"$4" not set in test_env"$ERED
	 	((IMAGE_ERR++))
		echo ""
		tmp=$tmp"<no-image>\t"
	else
		tmp=$tmp$image"\t"
	fi
	if [ -z $tag ]; then
	 	echo -e $RED"\$"$5" not set in test_env"$ERED
	 	((IMAGE_ERR++))
		echo ""
		tmp=$tmp"<no-tag>\t"
	else
		tmp=$tmp$tag
	fi
	echo -e "$tmp" >> $image_list_file
	#Export the env var
	export "${3}"=$image":"$tag

	#echo " Configured image for ${1} (script start arg=${2}): "$image":"$tag
}

# Check that image env setting are available
echo ""
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
	echo "Expected arg: local|remote|remote-remove [auto-clean]"
	exit 1
elif [ $1 == "local" ]; then

	#Local agent image
	__check_image_var " Policy Agent" $1 "POLICY_AGENT_IMAGE" "POLICY_AGENT_LOCAL_IMAGE" "POLICY_AGENT_LOCAL_IMAGE_TAG"

	#Local Control Panel image
	__check_image_var " Control Panel" $1 "CONTROL_PANEL_IMAGE" "CONTROL_PANEL_LOCAL_IMAGE" "CONTROL_PANEL_LOCAL_IMAGE_TAG"

	#Local SNDC image
	__check_image_var " SDNC A1 Controller" $1 "SDNC_A1_CONTROLLER_IMAGE" "SDNC_A1_CONTROLLER_LOCAL_IMAGE" "SDNC_A1_CONTROLLER_LOCAL_IMAGE_TAG"

	#Local ric sim image
	__check_image_var " RIC Simulator" $1 "RIC_SIM_IMAGE" "RIC_SIM_LOCAL_IMAGE" "RIC_SIM_LOCAL_IMAGE_TAG"

elif [ $1 == "remote" ] || [ $1 == "remote-remove" ]; then

	#Remote agent image
	__check_image_var " Policy Agent" $1 "POLICY_AGENT_IMAGE" "POLICY_AGENT_REMOTE_IMAGE" "POLICY_AGENT_REMOTE_IMAGE_TAG"

	#Remote Control Panel image
	__check_image_var " Control Panel" $1 "CONTROL_PANEL_IMAGE" "CONTROL_PANEL_REMOTE_IMAGE" "CONTROL_PANEL_REMOTE_IMAGE_TAG"

	#Remote SDNC image
	__check_image_var " SDNC A1 Controller" $1 "SDNC_A1_CONTROLLER_IMAGE" "SDNC_A1_CONTROLLER_REMOTE_IMAGE" "SDNC_A1_CONTROLLER_REMOTE_IMAGE_TAG"

	#Remote ric sim image
	__check_image_var " RIC Simulator" $1 "RIC_SIM_IMAGE" "RIC_SIM_REMOTE_IMAGE" "RIC_SIM_REMOTE_IMAGE_TAG"

else
	echo "Expected arg: local|remote|remote-remove [auto-clean]"
	exit 1
fi

if [ $# -eq 2 ]; then
	if [ $2 == "auto-clean" ]; then
		echo "Stting automatic cleaning of container when test case ends"
		AUTO_CLEAN="auto"
	else
		echo "Expected arg: local|remote|remote-remove [auto-clean]"
		exit 1
	fi
fi

# These images are not built as part of this project official images, just check that env vars are set correctly
__check_image_var " Message Router" $1 "MRSTUB_IMAGE" "MRSTUB_LOCAL_IMAGE" "MRSTUB_LOCAL_IMAGE_TAG"
__check_image_var " Callback Receiver" $1 "CR_IMAGE" "CR_LOCAL_IMAGE" "CR_LOCAL_IMAGE_TAG"
__check_image_var " Consul" $1 "CONSUL_IMAGE" "CONSUL_REMOTE_IMAGE" "CONSUL_REMOTE_IMAGE_TAG"
__check_image_var " CBS" $1 "CBS_IMAGE" "CBS_REMOTE_IMAGE" "CBS_REMOTE_IMAGE_TAG"
__check_image_var " SDNC DB" $1 "SDNC_DB_IMAGE" "SDNC_DB_REMOTE_IMAGE" "SDNC_DB_REMOTE_IMAGE_TAG"
__check_image_var " SDNC ONAP A1 Adapter" $1 "SDNC_ONAP_A1_ADAPTER_IMAGE" "SDNC_ONAP_A1_ADAPTER_REMOTE_IMAGE" "SDNC_ONAP_A1_ADAPTER_REMOTE_IMAGE_TAG"
__check_image_var " SDNC ONAP DB" $1 "SDNC_ONAP_DB_IMAGE" "SDNC_ONAP_DB_REMOTE_IMAGE" "SDNC_ONAP_DB_REMOTE_IMAGE_TAG"

#Errors in image setting - exit
if [ $IMAGE_ERR -ne 0 ]; then
	exit 1
fi

#Print a tables of the image settings
echo -e $BOLD"Images configured for start arg: "$1 $EBOLD
column -t -s $'\t' $image_list_file

echo ""


#Set the SIM_GROUP var
echo -e $BOLD"Setting var to main dir of all container/simulator scripts"$EBOLD
if [ -z "$SIM_GROUP" ]; then
	SIM_GROUP=$PWD/../simulator-group
	if [ ! -d  $SIM_GROUP ]; then
		echo "Trying to set env var SIM_GROUP to dir 'simulator-group' in the nontrtric repo, but failed."
		echo -e $RED"Please set the SIM_GROUP manually in the test_env.sh"$ERED
		exit 1
	else
		echo " SIM_GROUP auto set to: " $SIM_GROUP
	fi
elif [ $SIM_GROUP = *simulator_group ]; then
	echo -e $RED"Env var SIM_GROUP does not seem to point to dir 'simulator-group' in the repo, check common/test_env.sh"$ERED
	exit 1
else
	echo " SIM_GROUP env var already set to: " $SIM_GROUP
fi

echo ""

#Temp var to check for image pull errors
IMAGE_ERR=0

#Function to check if image exist and stop+remove the container+pull new images as needed
#args <script-start-arg> <descriptive-image-name> <container-base-name> <image-with-tag>
__check_and_pull_image() {

	echo -e " Checking $BOLD$2$EBOLD container(s) with basename: $BOLD$3$EBOLD using image: $BOLD$4$EBOLD"
	format_string="\"{{.Repository}}\\t{{.Tag}}\\t{{.CreatedSince}}\\t{{.Size}}\""
	tmp_im=$(docker images --format $format_string ${4})

	if [ $1 == "local" ]; then
		if [ -z "$tmp_im" ]; then
			echo -e "  "$2" (local image): \033[1m"$4"\033[0m $RED does not exist in local registry, need to be built (or manually pulled)"$ERED
			((IMAGE_ERR++))
			return 1
		else
			echo -e "  "$2" (local image): \033[1m"$4"\033[0m "$GREEN"OK"$EGREEN
		fi
	elif [ $1 == "remote" ] || [ $1 == "remote-remove" ]; then
		if [ $1 == "remote-remove" ]; then
			echo -ne "  Attempt to stop and remove container(s), if running - ${SAMELINE}"
			tmp="$(docker ps -aq --filter name=${3})"
			if [ $? -eq 0 ] && [ ! -z "$tmp" ]; then
				docker stop $tmp &> .dockererr
				if [ $? -ne 0 ]; then
					((IMAGE_ERR++))
					echo ""
					echo -e $RED"  Container(s) could not be stopped - try manual stopping the container(s)"$ERED
					cat .dockererr
					return 1
				fi
			fi
			echo -ne "  Attempt to stop and remove container(s), if running - "$GREEN"stopped"$EGREEN"${SAMELINE}"
			tmp="$(docker ps -aq --filter name=${3})" &> /dev/null
			if [ $? -eq 0 ] && [ ! -z "$tmp" ]; then
				docker rm $tmp &> .dockererr
				if [ $? -ne 0 ]; then
					((IMAGE_ERR++))
					echo ""
					echo -e $RED"  Container(s) could not be removed - try manual removal of the container(s)"$ERED
					cat .dockererr
					return 1
				fi
			fi
			echo -e "  Attempt to stop and remove container(s), if running - "$GREEN"stopped removed"$EGREEN
			echo -ne "  Removing image - ${SAMELINE}"
			tmp="$(docker images -q ${4})" &> /dev/null
			if [ $? -eq 0 ] && [ ! -z "$tmp" ]; then
				docker rmi $4 &> .dockererr
				if [ $? -ne 0 ]; then
					((IMAGE_ERR++))
					echo ""
					echo -e $RED"  Image could not be removed - try manual removal of the image"$ERED
					cat .dockererr
					return 1
				fi
				echo -e "  Removing image - "$GREEN"removed"$EGREEN
			else
				echo -e "  Removing image - "$GREEN"image not in repository"$EGREEN
			fi
			tmp_im=""
		fi
		if [ -z "$tmp_im" ]; then
			echo -ne "  Pulling image${SAMELINE}"
			docker pull $4	&> .dockererr
			tmp_im=$(docker images ${4} | grep -v REPOSITORY)
			if [ -z "$tmp_im" ]; then
				echo ""
				echo -e "  Pulling image -$RED could not be pulled"$ERED
				((IMAGE_ERR++))
				cat .dockererr
				return 1
			fi
			echo -e "  Pulling image -$GREEN Pulled $EGREEN"
		else
			echo -e "  Pulling image -$GREEN OK $EGREEN(exists in local repository)"
		fi
	fi
	return 0
}


echo -e $BOLD"Pulling configured images, if needed"$EBOLD

app="Policy Agent";             __check_and_pull_image $1 "$app" $POLICY_AGENT_APP_NAME $POLICY_AGENT_IMAGE
app="Non-RT RIC Control Panel"; __check_and_pull_image $1 "$app" $CONTROL_PANEL_APP_NAME $CONTROL_PANEL_IMAGE
app="SDNC A1 Controller";       __check_and_pull_image $1 "$app" $SDNC_APP_NAME $SDNC_A1_CONTROLLER_IMAGE
app="Near-RT RIC Simulator";    __check_and_pull_image $1 "$app" $RIC_SIM_PREFIX"_"$RIC_SIM_BASE $RIC_SIM_IMAGE

app="Consul";                   __check_and_pull_image $1 "$app" $CONSUL_APP_NAME $CONSUL_IMAGE
app="CBS";                      __check_and_pull_image $1 "$app" $CBS_APP_NAME $CBS_IMAGE
app="SDNC DB";                  __check_and_pull_image $1 "$app" $SDNC_APP_NAME $SDNC_DB_IMAGE

echo -e $YELLOW"SDNC ONAP image is skipped"$EYELLOW
#app="SDNC ONAP A1 Adapter";     __check_and_pull_image $1 "$app" $SDNC_ONAP_APP_NAME $SDNC_ONAP_A1_ADAPTER_IMAGE
#app="SDNC ONAP DB";             __check_and_pull_image $1 "$app" $SDNC_ONAP_APP_NAME $SDNC_ONAP_DB_IMAGE

# MR stub image not checked, will be built by this script - only local image
# CR stub image not checked, will be built by this script - only local image


#Errors in image setting - exit
if [ $IMAGE_ERR -ne 0 ]; then
	echo ""
	echo "#################################################################################################"
	echo -e $RED"One or more images could not be pulled or containers using the images could not be stopped/removed"$ERED
	echo "#################################################################################################"
	echo ""
	exit 1
fi

echo ""

echo -e $BOLD"Building images needed for test"$EBOLD

curdir=$PWD
cd $curdir
cd ../mrstub
echo " Building mrstub image: mrstub:latest"
docker build -t mrstub . &> .dockererr
if [ $? -eq 0 ]; then
	echo -e  $GREEN" Build Ok"$EGREEN
else
	echo -e $RED" Build Failed"$ERED
	((RES_CONF_FAIL++))
	cat .dockererr
fi
cd $curdir

cd ../cr
echo " Building Callback Receiver image: callback-receiver:latest"
docker build -t callback-receiver . &> .dockererr
if [ $? -eq 0 ]; then
	echo -e  $GREEN" Build Ok"$EGREEN
else
	echo -e $RED" Build Failed"$ERED
	((RES_CONF_FAIL++))
	cat .dockererr
fi
cd $curdir

echo ""

# Create a table of the images used in the script
echo -e $BOLD"Local docker registry images used in the this test script"$EBOLD

docker_tmp_file=.docker-images-table
format_string="{{.Repository}}\\t{{.Tag}}\\t{{.CreatedSince}}\\t{{.Size}}"
echo -e " Application\tRepository\tTag\tCreated Since\tSize" > $docker_tmp_file
echo -e " Policy Agent\t$(docker images --format $format_string $POLICY_AGENT_IMAGE)" >>   $docker_tmp_file
echo -e " Control Panel\t$(docker images --format $format_string $CONTROL_PANEL_IMAGE)" >>   $docker_tmp_file
echo -e " SDNC A1 Controller\t$(docker images --format $format_string $SDNC_A1_CONTROLLER_IMAGE)" >>   $docker_tmp_file
echo -e " RIC Simulator\t$(docker images --format $format_string $RIC_SIM_IMAGE)" >>   $docker_tmp_file
echo -e " Message Router\t$(docker images --format $format_string $MRSTUB_IMAGE)" >>   $docker_tmp_file
echo -e " Callback Receiver\t$(docker images --format $format_string $CR_IMAGE)" >>   $docker_tmp_file
echo -e " Consul\t$(docker images --format $format_string $CONSUL_IMAGE)" >>   $docker_tmp_file
echo -e " CBS\t$(docker images --format $format_string $CBS_IMAGE)" >>   $docker_tmp_file
echo -e " SDNC DB\t$(docker images --format $format_string $SDNC_DB_IMAGE)" >>   $docker_tmp_file
echo -e " SDNC ONAP A1 Adapter\t$(docker images --format $format_string $SDNC_ONAP_A1_ADAPTER_IMAGE)" >>   $docker_tmp_file
echo -e " SDNC ONAP DB\t$(docker images --format $format_string $SDNC_ONAP_DB_IMAGE)" >>   $docker_tmp_file

column -t -s $'\t' $docker_tmp_file

echo ""

echo -e $BOLD"======================================================="$EBOLD
echo -e $BOLD"== Common test setup completed -  test script begins =="$EBOLD
echo -e $BOLD"======================================================="$EBOLD
echo ""

# Function to print the test result, shall be the last cmd in a test script
# args: -
# (Function for test scripts)
print_result() {

	TCTEST_END=$SECONDS
	duration=$((TCTEST_END-TCTEST_START))

	echo "-------------------------------------------------------------------------------------------------"
	echo "-------------------------------------     Test case: "$ATC
	echo "-------------------------------------     Ended:     "$(date)
	echo "-------------------------------------------------------------------------------------------------"
	echo "-- Description: "$TC_ONELINE_DESCR
	echo "-- Execution time: " $duration " seconds"
	echo "-------------------------------------------------------------------------------------------------"
	echo "-------------------------------------     RESULTS"
	echo ""


	total=$((RES_PASS+RES_FAIL))
	if [ $RES_TEST -eq 0 ]; then
		echo -e "\033[1mNo tests seem to have been executed. Check the script....\033[0m"
 		echo -e "\033[31m\033[1m ___  ___ ___ ___ ___ _____   ___ _   ___ _   _   _ ___ ___ \033[0m"
 		echo -e "\033[31m\033[1m/ __|/ __| _ \_ _| _ \_   _| | __/_\ |_ _| | | | | | _ \ __|\033[0m"
		echo -e "\033[31m\033[1m\__ \ (__|   /| ||  _/ | |   | _/ _ \ | || |_| |_| |   / _| \033[0m"
 		echo -e "\033[31m\033[1m|___/\___|_|_\___|_|   |_|   |_/_/ \_\___|____\___/|_|_\___|\033[0m"
	elif [ $total != $RES_TEST ]; then
		echo -e "\033[1mTotal number of tests does not match the sum of passed and failed tests. Check the script....\033[0m"
		echo -e "\033[31m\033[1m ___  ___ ___ ___ ___ _____   ___ _   ___ _   _   _ ___ ___ \033[0m"
		echo -e "\033[31m\033[1m/ __|/ __| _ \_ _| _ \_   _| | __/_\ |_ _| | | | | | _ \ __|\033[0m"
		echo -e "\033[31m\033[1m\__ \ (__|   /| ||  _/ | |   | _/ _ \ | || |_| |_| |   / _| \033[0m"
 		echo -e "\033[31m\033[1m|___/\___|_|_\___|_|   |_|   |_/_/ \_\___|____\___/|_|_\___|\033[0m"
	elif [ $RES_CONF_FAIL -ne 0 ]; then
		echo -e "\033[1mOne or more configure regest has failed. Check the script log....\033[0m"
		echo -e "\033[31m\033[1m ___  ___ ___ ___ ___ _____   ___ _   ___ _   _   _ ___ ___ \033[0m"
		echo -e "\033[31m\033[1m/ __|/ __| _ \_ _| _ \_   _| | __/_\ |_ _| | | | | | _ \ __|\033[0m"
		echo -e "\033[31m\033[1m\__ \ (__|   /| ||  _/ | |   | _/ _ \ | || |_| |_| |   / _| \033[0m"
 		echo -e "\033[31m\033[1m|___/\___|_|_\___|_|   |_|   |_/_/ \_\___|____\___/|_|_\___|\033[0m"
	elif [ $RES_PASS = $RES_TEST ]; then
		echo -e "All tests \033[32m\033[1mPASS\033[0m"
		echo -e "\033[32m\033[1m  ___  _   ___ ___ \033[0m"
		echo -e "\033[32m\033[1m | _ \/_\ / __/ __| \033[0m"
		echo -e "\033[32m\033[1m |  _/ _ \\__ \__ \\ \033[0m"
		echo -e "\033[32m\033[1m |_|/_/ \_\___/___/ \033[0m"
		echo ""

		# Update test suite counter
		if [ -f .tmp_tcsuite_pass_ctr ]; then
			tmpval=$(< .tmp_tcsuite_pass_ctr)
			((tmpval++))
			echo $tmpval > .tmp_tcsuite_pass_ctr
		fi
		if [ -f .tmp_tcsuite_pass ]; then
			echo " - "$ATC " -- "$TC_ONELINE_DESCR"  Execution time: "$duration" seconds" >> .tmp_tcsuite_pass
		fi
	else
		echo -e "One or more tests with status  \033[31m\033[1mFAIL\033[0m "
		echo -e "\033[31m\033[1m  ___ _   ___ _    \033[0m"
		echo -e "\033[31m\033[1m | __/_\ |_ _| |   \033[0m"
		echo -e "\033[31m\033[1m | _/ _ \ | || |__ \033[0m"
		echo -e "\033[31m\033[1m |_/_/ \_\___|____|\033[0m"
		echo ""
		# Update test suite counter
		if [ -f .tmp_tcsuite_fail_ctr ]; then
			tmpval=$(< .tmp_tcsuite_fail_ctr)
			((tmpval++))
			echo $tmpval > .tmp_tcsuite_fail_ctr
		fi
		if [ -f .tmp_tcsuite_fail ]; then
			echo " - "$ATC " -- "$TC_ONELINE_DESCR"  Execution time: "$duration" seconds" >> .tmp_tcsuite_fail
		fi
	fi

	if [ $RES_DEVIATION -gt 0 ]; then
		echo "Test case deviations"
		echo "===================================="
		cat $DEVIATION_FILE
	fi
	echo ""
	echo "Timer measurement in the test script"
	echo "===================================="
	column -t -s $'\t' $TIMER_MEASUREMENTS
	echo ""

	echo "++++ Number of tests:          "$RES_TEST
	echo "++++ Number of passed tests:   "$RES_PASS
	echo "++++ Number of failed tests:   "$RES_FAIL
	echo ""
	echo "++++ Number of failed configs: "$RES_CONF_FAIL
	echo ""
	echo "++++ Number of test case deviations: "$RES_DEVIATION
	echo ""
	echo "-------------------------------------     Test case complete    ---------------------------------"
	echo "-------------------------------------------------------------------------------------------------"
	echo ""
}

#####################################################################
###### Functions for start, configuring, stoping, cleaning etc ######
#####################################################################

# Start timer for time measurement
# args - (any args will be printed though)
start_timer() {
	echo -e $BOLD"INFO(${BASH_LINENO[0]}): "${FUNCNAME[0]}"," $@ $EBOLD
	TC_TIMER=$SECONDS
	echo " Timer started"
}

# Print the value of the time (in seconds)
# args - <timer message to print>  -  timer value and message will be printed both on screen
#                                     and in the timer measurement report
print_timer() {
	echo -e $BOLD"INFO(${BASH_LINENO[0]}): "${FUNCNAME[0]}"," $@ $EBOLD
	if [ $# -lt 1 ]; then
		((RES_CONF_FAIL++))
    	__print_err "need 1 or more args,  <timer message to print>" $@
		exit 1
	fi
	duration=$(($SECONDS-$TC_TIMER))
	if [ $duration -eq 0 ]; then
		duration="<1 second"
	else
		duration=$duration" seconds"
	fi
	echo " Timer duration :" $duration

	echo -e "${@:1} \t $duration" >> $TIMER_MEASUREMENTS
}

# Print the value of the time (in seconds) and reset the timer
# args - <timer message to print>  -  timer value and message will be printed both on screen
#                                     and in the timer measurement report
print_and_reset_timer() {
	echo -e $BOLD"INFO(${BASH_LINENO[0]}): "${FUNCNAME[0]}"," $@ $EBOLD
	if [ $# -lt 1 ]; then
		((RES_CONF_FAIL++))
    	__print_err "need 1 or more args,  <timer message to print>" $@
		exit 1
	fi
	duration=$(($SECONDS-$TC_TIMER))" seconds"
	if [ $duration -eq 0 ]; then
		duration="<1 second"
	else
		duration=$duration" seconds"
	fi
	echo " Timer duration :" $duration
	TC_TIMER=$SECONDS
	echo " Timer reset"

	echo -e "${@:1} \t $duration" >> $TIMER_MEASUREMENTS

}
# Print info about a deviations from intended tests
# Each deviation counted is also printed in the testreport
# args <deviation message to print>
deviation() {
	echo -e $BOLD"DEVIATION(${BASH_LINENO[0]}): "${FUNCNAME[0]} $EBOLD
	if [ $# -lt 1 ]; then
		((RES_CONF_FAIL++))
		__print_err "need 1 or more args,  <deviation message to print>" $@
		exit 1
	fi
	((RES_DEVIATION++))
	echo -e $BOLD$YELLOW" Test case deviation: ${@:1}"$EYELLOW$EBOLD
	echo "Line: ${BASH_LINENO[0]} - ${@:1}" >> $DEVIATION_FILE
	echo ""
}

# Stop and remove all containers
# args: -
# (Function for test scripts)
clean_containers() {

	echo -e $BOLD"Stopping and removing all running containers, by container name"$EBOLD

	CONTAINTER_NAMES=("Policy Agent           " $POLICY_AGENT_APP_NAME\
					  "Non-RT RIC Simulator(s)" $RIC_SIM_PREFIX\
					  "Message Router         " $MR_APP_NAME\
					  "Callback Receiver      " $CR_APP_NAME\
					  "Control Panel          " $CONTROL_PANEL_APP_NAME\
					  "SDNC A1 Controller     " $SDNC_APP_NAME\
					  "SDNC DB                " $SDNC_DB_APP_NAME\
					  "SDNC ONAP A1 Adapter   " $SDNC_ONAP_APP_NAME\
					  "SDNC DB                " $SDNC_ONAP_DB_APP_NAME\
					  "CBS                    " $CBS_APP_NAME\
					  "Consul                 " $CONSUL_APP_NAME)

	nw=0 # Calc max width of container name, to make a nice table
	for (( i=1; i<${#CONTAINTER_NAMES[@]} ; i+=2 )) ; do
		if [ ${#CONTAINTER_NAMES[i]} -gt $nw ]; then
			nw=${#CONTAINTER_NAMES[i]}
		fi
	done

	for (( i=0; i<${#CONTAINTER_NAMES[@]} ; i+=2 )) ; do
		APP="${CONTAINTER_NAMES[i]}"
		CONTR="${CONTAINTER_NAMES[i+1]}"
		for((w=${#CONTR}; w<$nw; w=w+1)); do
			CONTR="$CONTR "
		done
		echo -ne " $APP: $CONTR - ${GREEN}stopping${EGREEN}${SAMELINE}"
		docker stop $(docker ps -qa --filter name=${CONTR}) &> /dev/null
		echo -ne " $APP: $CONTR - ${GREEN}stopped${EGREEN}${SAMELINE}"
		docker rm $(docker ps -qa --filter name=${CONTR}) &> /dev/null
		echo -e  " $APP: $CONTR - ${GREEN}stopped removed${EGREEN}"
	done

	echo ""
}

# Function stop and remove all container in the end of the test script, if the arg 'auto-clean' is given at test script start
# args: -
# (Function for test scripts)
auto_clean_containers() {
	echo
	if [ "$AUTO_CLEAN" == "auto" ]; then
		echo -e $BOLD"Initiating automatic cleaning of started containers"$EBOLD
		clean_containers
	fi
}

# Function to sleep a test case for a numner of seconds. Prints the optional text args as info
# args: <sleep-time-in-sec> [any-text-in-quoteds-to-printed]
# (Function for test scripts)
sleep_wait() {

	echo -e $BOLD"INFO(${BASH_LINENO[0]}): "${FUNCNAME[0]}"," $@ $EBOLD
	if [ $# -lt 1 ]; then
		((RES_CONF_FAIL++))
		__print_err "need at least one arg, <sleep-time-in-sec> [any-text-to-printed]" $@
		exit 1
	fi
	#echo "---- Sleep for " $1 " seconds ---- "$2
	start=$SECONDS
	duration=$((SECONDS-start))
	while [ $duration -lt $1 ]; do
		echo -ne "  Slept for ${duration} seconds${SAMELINE}"
		sleep 1
		duration=$((SECONDS-start))
	done
	echo -ne "  Slept for ${duration} seconds${SAMELINE}"
	echo ""
}

# Print error info for the call in the parent script (test case). Arg: <error-message-to-print>
# Not to be called from the test script itself.
__print_err() {
    echo -e $RED ${FUNCNAME[1]} " "$1" " ${BASH_SOURCE[2]} " line" ${BASH_LINENO[1]} $ERED
	if [ $# -gt 1 ]; then
		echo -e $RED" Got: "${FUNCNAME[1]} ${@:2} $ERED
	fi
}


# Helper function to get a the port of a specific ric simulatpor
# args: <ric-id>
# (Not for test scripts)
__find_sim_port() {
    name=$1" " #Space appended to prevent matching 10 if 1 is desired....
    cmdstr="docker inspect --format='{{(index (index .NetworkSettings.Ports \"$RIC_SIM_PORT/tcp\") 0).HostPort}}' ${name}"
    res=$(eval $cmdstr)
	if [[ "$res" =~ ^[0-9]+$ ]]; then
		echo $res
	else
		echo "0"
    fi
}

# Function to create the docker network for the test
# Not to be called from the test script itself.
__create_docker_network() {
	tmp=$(docker network ls --format={{.Name}} --filter name=$DOCKER_SIM_NWNAME)
	if [ $? -ne 0 ]; then
		echo -e $RED" Could not check if docker network $DOCKER_SIM_NWNAME exists"$ERED
		return 1
	fi
	if [ "$tmp" != $DOCKER_SIM_NWNAME ]; then
		echo -e "Creating docker network:$BOLD $DOCKER_SIM_NWNAME $EBOLD"
		docker network create $DOCKER_SIM_NWNAME
		if [ $? -ne 0 ]; then
			echo -e $RED" Could not create docker network $DOCKER_SIM_NWNAME"$ERED
			return 1
		fi
	else
		echo -e " Docker network $DOCKER_SIM_NWNAME already exists$GREEN OK $EGREEN"
	fi
}

# Check if container is started by calling url on localhost using a port, expects response code 2XX
# args: <container-name> <port> <url> https|https
# Not to be called from the test script itself.
__check_container_start() {
	paramError=0
	if [ $# -ne 4 ]; then
		paramError=1
	elif [ $4 != "http" ] && [ $4 != "https" ]; then
		paramError=1
	fi
	if [ $paramError -ne 0 ]; then
		((RES_CONF_FAIL++))
		__print_err "need 3 args, <container-name> <port> <url> https|https" $@
		return 1
	fi
	echo -ne " Container $BOLD$1$EBOLD starting${SAMELINE}"
	appname=$1
	localport=$2
	url=$3
	if [[ $appname != "STANDALONE_"* ]]	; then
		app_started=0
		for i in {1..10}; do
			if [ "$(docker inspect --format '{{ .State.Running }}' $appname)" == "true" ]; then
					echo -e " Container $BOLD$1$EBOLD$GREEN running$EGREEN on$BOLD image $(docker inspect --format '{{ .Config.Image }}' ${appname}) $EBOLD"
					app_started=1
					break
				else
					sleep $i
			fi
		done
		if [ $app_started -eq 0 ]; then
			((RES_CONF_FAIL++))
			echo ""
			echo -e $RED" Container $BOLD${appname}$EBOLD could not be started"$ERED
			return 1
		fi
		if [ $localport -eq 0 ]; then
			while [ $localport -eq 0 ]; do
				echo -ne " Waiting for container ${appname} to publish its ports...${SAMELINE}"
				localport=$(__find_sim_port $appname)
				sleep 1
				echo -ne " Waiting for container ${appname} to publish its ports...retrying....${SAMELINE}"
			done
			echo -ne " Waiting for container ${appname} to publish its ports...retrying....$GREEN OK $EGREEN"
			echo ""
		fi
	fi

	pa_st=false
	echo -ne " Waiting for container ${appname} service status...${SAMELINE}"
	for i in {1..20}; do
		if [ $4 == "https" ]; then
			result="$(__do_curl "-k https://localhost:"${localport}${url})"
		else
			result="$(__do_curl $LOCALHOST${localport}${url})"
		fi
		if [ $? -eq 0 ]; then
			if [ ${#result} -gt 15 ]; then
				#If response is too long, truncate
				result="...response text too long, omitted"
			fi
			echo -ne " Waiting for container $BOLD${appname}$EBOLD service status, result: $result${SAMELINE}"
	   		echo -ne " Container $BOLD${appname}$EBOLD$GREEN is alive$EGREEN, responds to service status:$GREEN $result $EGREEN"
	   		pa_st=true
	   		break
	 	else
			#echo " Retrying in $i seconds"
			echo -ne " Waiting for container ${appname} service status...retrying in $i seconds${SAMELINE}"
	   		sleep $i
	 	fi
	done

	if [ "$pa_st" = "false"  ]; then
		((RES_CONF_FAIL++))
		echo -e $RED" Container ${appname} did not respond to service status"$ERED
		return 0
	fi

	echo ""
	return 0
}


# Function to start a container and wait until it responds on the given port and url.
#args: <docker-compose-dir> NODOCKERARGS|<docker-compose-arg> <app-name> <port-number> <alive-url> [<app-name> <port-number> <alive-url>]*
__start_container() {

	variableArgCount=$(($#-2))
	if [ $# -lt 6 ] && [ [ $(($variableArgCount%4)) -ne 0 ]; then
		((RES_CONF_FAIL++))
    	__print_err "need 6 or more args,  <docker-compose-dir> NODOCKERARGS|<docker-compose-arg> <app-name> <port-number> <alive-url> http|https [<app-name> <port-number> <alive-url> http|https ]*" $@
		exit 1
	fi

	__create_docker_network

	curdir=$PWD
	cd $SIM_GROUP
	cd $1

	if [ "$2" == "NODOCKERARGS" ]; then
		docker-compose up -d &> .dockererr
		if [ $? -ne 0 ]; then
			echo -e $RED"Problem to launch container(s) with docker-compose"$ERED
			cat .dockererr
		fi
	elif [ "$2" == "STANDALONE" ]; then
		echo "Skipping docker-compose"
	else
		docker-compose up -d $2 &> .dockererr
		if [ $? -ne 0 ]; then
			echo -e $RED"Problem to launch container(s) with docker-compose"$ERED
			cat .dockererr
		fi
	fi
	app_prefix=""
	if [ "$2" == "STANDALONE" ]; then
		app_prefix="STANDALONE_"
	fi
	shift; shift;
	cntr=0
	while [ $cntr -lt $variableArgCount ]; do
		app=$app_prefix$1; shift;
		port=$1; shift;
		url=$1; shift;
		httpx=$1; shift;
		let cntr=cntr+4

		__check_container_start "$app" "$port" "$url" $httpx
	done

	cd $curdir
	echo ""
	return 0
}

####################
### Consul functions
####################

# Function to load config from a file into consul for the Policy Agent
# arg: <json-config-file>
# (Function for test scripts)
consul_config_app() {

	echo -e $BOLD"Configuring Consul"$EBOLD

	if [ $# -ne 1 ]; then
		((RES_CONF_FAIL++))
    	__print_err "need one arg,  <json-config-file>" $@
		exit 1
	fi

	echo " Loading config for "$POLICY_AGENT_APP_NAME" from "$1

	curl -s $LOCALHOST${CONSUL_EXTERNAL_PORT}/v1/kv/${POLICY_AGENT_APP_NAME}?dc=dc1 -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' --data-binary "@"$1 >/dev/null
	if [ $? -ne 0 ]; then
		echo -e $RED" FAIL - json config could not be loaded to consul" $ERED
		((RES_CONF_FAIL++))
		return 1
	fi
	body="$(__do_curl $LOCALHOST$CBS_EXTERNAL_PORT/service_component_all/$POLICY_AGENT_APP_NAME)"
	echo $body > ".output"$1

	if [ $? -ne 0 ]; then
		echo -e $RED" FAIL - json config could not be loaded from consul/cbs, contents cannot be checked." $ERED
		((RES_CONF_FAIL++))
		return 1
	else
		targetJson=$(< $1)
		targetJson="{\"config\":"$targetJson"}"
		echo "TARGET JSON: $targetJson" >> $HTTPLOG
		res=$(python3 ../common/compare_json.py "$targetJson" "$body")
		if [ $res -ne 0 ]; then
			echo -e $RED" FAIL - policy json config read from consul/cbs is not equal to the intended json config...." $ERED
			((RES_CONF_FAIL++))
			return 1
		else
			echo -e $GREEN" Config loaded ok to consul"$EGREEN
		fi
	fi

	echo ""

}

# Function to perpare the consul configuration according to the current simulator configuration
# args: SDNC|SDNC_ONAP|NOSDNC <output-file>
# (Function for test scripts)
prepare_consul_config() {
  	echo -e $BOLD"Prepare Consul config"$EBOLD

	echo " Writing consul config for "$POLICY_AGENT_APP_NAME" to file: "$2

	if [ $# != 2 ];  then
		((RES_CONF_FAIL++))
    	__print_err "need two args,  SDNC|SDNC_ONAP|NOSDNC <output-file>" $@
		exit 1
	fi

	if [ $1 == "SDNC" ]; then
		echo -e " Config$BOLD including SDNC$EBOLD configuration"
	elif [ $1 == "SDNC_ONAP" ]; then
		echo -e " Config$BOLD including SDNC ONAP$EBOLD configuration"
	elif [ $1 == "NOSDNC" ];  then
		echo -e " Config$BOLD excluding SDNC or SDNC ONAP$EBOLD configuration"
	else
		((RES_CONF_FAIL++))
    	__print_err "need two args,  SDNC|SDNC_ONAP|NOSDNC <output-file>" $@
		exit 1
	fi

	config_json="\n            {"
	if [ $1 == "SDNC" ]; then
		config_json=$config_json"\n   \"controller\": ["
		config_json=$config_json"\n                     {"
		config_json=$config_json"\n                       \"name\": \"$SDNC_APP_NAME\","
		if [ $AGENT_STAND_ALONE -eq 0 ]; then
			config_json=$config_json"\n                       \"baseUrl\": \"$SDNC_HTTPX://$SDNC_APP_NAME:$SDNC_PORT\","
		else
			config_json=$config_json"\n                       \"baseUrl\": \"$SDNC_HTTPX://localhost:$SDNC_LOCAL_PORT\","
		fi
		config_json=$config_json"\n                       \"userName\": \"$SDNC_USER\","
		config_json=$config_json"\n                       \"password\": \"$SDNC_PWD\""
		config_json=$config_json"\n                     }"
		config_json=$config_json"\n   ],"
	fi
	if [ $1 == "SDNC_ONAP" ]; then
		config_json=$config_json"\n   \"controller\": ["
		config_json=$config_json"\n                     {"
		config_json=$config_json"\n                       \"name\": \"$SDNC_ONAP_APP_NAME\","
		if [ $AGENT_STAND_ALONE -eq 0 ]; then
			config_json=$config_json"\n                       \"baseUrl\": \"http://$SDNC_ONAP_APP_NAME:$SDNC_ONAP_INTERNAL_PORT\","
		else
			config_json=$config_json"\n                       \"baseUrl\": \"http://localhost:$SDNC_ONAP_EXTERNAL_PORT\","
		fi
		config_json=$config_json"\n                       \"userName\": \"$SDNC_ONAP_USER\","
		config_json=$config_json"\n                       \"password\": \"$SDNC_ONAP_PWD\""
		config_json=$config_json"\n                     }"
		config_json=$config_json"\n   ],"
	fi


	config_json=$config_json"\n   \"streams_publishes\": {"
	config_json=$config_json"\n                            \"dmaap_publisher\": {"
	config_json=$config_json"\n                              \"type\": \"$MR_APP_NAME\","
	config_json=$config_json"\n                              \"dmaap_info\": {"
	if [ $AGENT_STAND_ALONE -eq 0 ]; then
		config_json=$config_json"\n                                \"topic_url\": \"$MR_HTTPX://$MR_APP_NAME:$MR_PORT$MR_WRITE_URL\""
	else
		config_json=$config_json"\n                                \"topic_url\": \"$MR_HTTPX://localhost:$MR_LOCAL_PORT$MR_WRITE_URL\""
	fi
	config_json=$config_json"\n                              }"
	config_json=$config_json"\n                            }"
	config_json=$config_json"\n   },"
	config_json=$config_json"\n   \"streams_subscribes\": {"
	config_json=$config_json"\n                             \"dmaap_subscriber\": {"
	config_json=$config_json"\n                               \"type\": \"$MR_APP_NAME\","
	config_json=$config_json"\n                               \"dmaap_info\": {"
	if [ $AGENT_STAND_ALONE -eq 0 ]; then
		config_json=$config_json"\n                                   \"topic_url\": \"$MR_HTTPX://$MR_APP_NAME:$MR_PORT$MR_READ_URL\""
	else
		config_json=$config_json"\n                                   \"topic_url\": \"$MR_HTTPX://localhost:$MR_LOCAL_PORT$MR_READ_URL\""
	fi
	config_json=$config_json"\n                                 }"
	config_json=$config_json"\n                               }"
	config_json=$config_json"\n   },"

	config_json=$config_json"\n   \"ric\": ["

	rics=$(docker ps | grep ricsim | awk '{print $NF}')

	if [ $? -ne 0 ] || [ -z "$rics" ]; then
		echo -e $RED" FAIL - the names of the running RIC Simulator cannot be retrieved." $ERED
		((RES_CONF_FAIL++))
		return 1
	fi

	cntr=0
	for ric in $rics; do
		if [ $cntr -gt 0 ]; then
			config_json=$config_json"\n          ,"
		fi
		config_json=$config_json"\n          {"
		config_json=$config_json"\n            \"name\": \"$ric\","
		if [ $AGENT_STAND_ALONE -eq 0 ]; then
			config_json=$config_json"\n            \"baseUrl\": \"$RIC_SIM_HTTPX://$ric:$RIC_SIM_PORT\","
		else
			config_json=$config_json"\n            \"baseUrl\": \"$RIC_SIM_HTTPX://localhost:$(__find_sim_port $ric)\","
		fi
		if [ $1 == "SDNC" ]; then
			config_json=$config_json"\n            \"controller\": \"$SDNC_APP_NAME\","
		elif [ $1 == "SDNC_ONAP" ]; then
			config_json=$config_json"\n            \"controller\": \"$SDNC_ONAP_APP_NAME\","
		fi
		config_json=$config_json"\n            \"managedElementIds\": ["
		config_json=$config_json"\n              \"me1_$ric\","
		config_json=$config_json"\n              \"me2_$ric\""
		config_json=$config_json"\n            ]"
		config_json=$config_json"\n          }"
		let cntr=cntr+1
	done

	config_json=$config_json"\n           ]"
	config_json=$config_json"\n}"


	printf "$config_json">$2

	echo ""
}


# Start Consul and CBS
# args: -
# (Function for test scripts)
start_consul_cbs() {

	echo -e $BOLD"Starting Consul and CBS"$EBOLD

	__start_container consul_cbs NODOCKERARGS  "$CONSUL_APP_NAME" "$CONSUL_EXTERNAL_PORT" "/ui/dc1/kv" "http" \
	                                             "$CBS_APP_NAME" "$CBS_EXTERNAL_PORT" "/healthcheck" "http"
}

###########################
### RIC Simulator functions
###########################

use_simulator_http() {
	echo -e "Using unsecure $BOLD http $EBOLD towards the simulators"
	export RIC_SIM_HTTPX="http"
	export RIC_SIM_LOCALHOST=$RIC_SIM_HTTPX"://localhost:"
	export RIC_SIM_PORT=$RIC_SIM_INTERNAL_PORT
	echo ""
}

use_simulator_https() {
	echo -e "Using secure $BOLD https $EBOLD towards the simulators"
	export RIC_SIM_HTTPX="https"
	export RIC_SIM_LOCALHOST=$RIC_SIM_HTTPX"://localhost:"
	export RIC_SIM_PORT=$RIC_SIM_INTERNAL_SECURE_PORT
	echo ""
}

# Start one group (ricsim_g1, ricsim_g2 or ricsim_g3) with a number of RIC Simulators using a given A interface
# args:  ricsim_g1|ricsim_g2|ricsim_g3 <count> <interface-id>
# (Function for test scripts)
start_ric_simulators() {

	echo -e $BOLD"Starting RIC Simulators"$EBOLD

	if [ $# != 3 ]; then
		((RES_CONF_FAIL++))
    	__print_err "need three args,  ricsim_g1|ricsim_g2|ricsim_g3 <count> <interface-id>" $@
		exit 1
	fi
	echo " $2 simulators using basename: $1 on interface: $3"
	#Set env var for simulator count and A1 interface vesion for the given group
	if [ $1 == "ricsim_g1" ]; then
		G1_COUNT=$2
		G1_A1_VERSION=$3
	elif [ $1 == "ricsim_g2" ]; then
		G2_COUNT=$2
		G2_A1_VERSION=$3
	elif [ $1 == "ricsim_g3" ]; then
		G3_COUNT=$2
		G3_A1_VERSION=$3
	else
		((RES_CONF_FAIL++))
    	__print_err "need three args, gricsim_g1|ricsim_g2|ricsim_g3 <count> <interface-id>" $@
		exit 1
	fi

	# Create .env file to compose project, all ric container will get this prefix
	echo "COMPOSE_PROJECT_NAME="$RIC_SIM_PREFIX > $SIM_GROUP/ric/.env

	export G1_A1_VERSION
	export G2_A1_VERSION
	export G3_A1_VERSION

	docker_args="--scale g1=$G1_COUNT --scale g2=$G2_COUNT --scale g3=$G3_COUNT"
	app_data=""
	cntr=1
	while [ $cntr -le $2 ]; do
		app=$1"_"$cntr
		port=0
		app_data="$app_data $app $port / "$RIC_SIM_HTTPX
		let cntr=cntr+1
	done
	__start_container ric "$docker_args" $app_data

}

###########################
### Control Panel functions
###########################

# Start the Control Panel container
# args: -
# (Function for test scripts)
start_control_panel() {

	echo -e $BOLD"Starting Control Panel"$EBOLD

	__start_container control_panel NODOCKERARGS $CONTROL_PANEL_APP_NAME $CONTROL_PANEL_EXTERNAL_PORT "/" "http"

}

##################
### SDNC functions
##################

# Start the SDNC A1 Controller
# args: -
# (Function for test scripts)
start_sdnc() {

	echo -e $BOLD"Starting SDNC A1 Controller"$EBOLD

	__start_container sdnc NODOCKERARGS $SDNC_APP_NAME $SDNC_EXTERNAL_PORT $SDNC_ALIVE_URL "http"

}

use_sdnc_http() {
	echo -e $BOLD"Using http between agent and SDNC"$EBOLD
	export SDNC_HTTPX="http"
	export SDNC_PORT=$SDNC_INTERNAL_PORT
	export SDNC_LOCAL_PORT=$SDNC_EXTERNAL_PORT
	echo ""
}

use_sdnc_https() {
	echo -e $BOLD"Using https between agent and SDNC"$EBOLD
	export SDNC_HTTPX="https"
	export SDNC_PORT=$SDNC_INTERNAL_SECURE_PORT
	export SDNC_LOCAL_PORT=$SDNC_EXTERNAL_SECURE_PORT
	echo ""
}

#######################
### SDNC ONAP functions
#######################

# Start the SDNC ONAP A1 Adapter
# args: -
# (Function for test scripts)
start_sdnc_onap() {

	echo -e $BOLD"Starting SDNC ONAP A1 Adapter"$EBOLD

	__start_container sdnc_onap NODOCKERARGS $SDNC_ONAP_APP_NAME $SDNC_ONAP_EXTERNAL_PORT $SDNC_ONAP_ALIVE_URL "http"

}

# Configure the SDNC ONAP A1 Adapter
# args: -
# (Function for test scripts)
config_sdnc_onap() {

	echo -e $BOLD"Configuring SDNC ONAP A1 Adapter"$EBOLD

	LOCALFILE=".sdnc_onap.prop"
	REMOTEFILE="/tmp/.sdnc_onap.prop"

	docker cp $SDNC_ONAP_APP_NAME:$SDNC_ONAP_PROPERTIES_FILE $LOCALFILE
	if [ $? -ne 0 ]; then
		echo -e $RED"Could not copy $SDNC_ONAP_PROPERTIES_FILE from $SDNC_ONAP_APP_NAME container"$ERED
		exit 1
	fi


	#Config of the prop file shall be inserted here

	#Copy file to /tmp and then to final destination, a trick to get correct permission of the file.

	docker cp $LOCALFILE $SDNC_ONAP_APP_NAME:$REMOTEFILE
	if [ $? -ne 0 ]; then
		echo -e $RED"Could not copy local $LOCALFILE to $REMOTEFILE in $SDNC_ONAP_APP_NAME container"$ERED
		exit 1
	fi

	docker exec -it $SDNC_ONAP_APP_NAME cp $REMOTEFILE $SDNC_ONAP_PROPERTIES_FILE
	if [ $? -ne 0 ]; then
		echo -e $RED"Could not copy $REMOTEFILE to $SDNC_ONAP_PROPERTIES_FILE in $SDNC_ONAP_APP_NAME container"$ERED
		exit 1
	fi
}

#####################
### MR stub functions
#####################

# Start the Message Router stub interface in the simulator group
# args: -
# (Function for test scripts)
start_mr() {

	echo -e $BOLD"Starting Message Router 'mrstub'"$EBOLD
	export MR_CERT_MOUNT_DIR="./cert"
	__start_container mr NODOCKERARGS $MR_APP_NAME $MR_EXTERNAL_PORT "/" "http"
}

use_mr_http() {
	echo -e $BOLD"Using http between agent and MR"$EBOLD
	export MR_HTTPX="http"
	export MR_PORT=$MR_INTERNAL_PORT
	export MR_LOCAL_PORT=$MR_EXTERNAL_PORT
	echo ""
}

use_mr_https() {
	echo -e $BOLD"Using https between agent and MR"$EBOLD
	export MR_HTTPX="https"
	export MR_PORT=$MR_INTERNAL_SECURE_PORT
	export MR_LOCAL_PORT=$MR_EXTERNAL_SECURE_PORT
	echo ""
}


################
### CR functions
################

# Start the Callback reciver in the simulator group
# args: -
# (Function for test scripts)
start_cr() {

	echo -e $BOLD"Starting Callback Receiver"$EBOLD

	__start_container cr NODOCKERARGS $CR_APP_NAME $CR_EXTERNAL_PORT "/" "http"

}

###########################
### Policy Agents functions
###########################

# Use an agent on the local machine instead of container
use_agent_stand_alone() {
	AGENT_STAND_ALONE=1
}

# Start the policy agent
# args: -
# (Function for test scripts)
start_policy_agent() {

	echo -e $BOLD"Starting Policy Agent"$EBOLD

	if [ $AGENT_STAND_ALONE -eq 0 ]; then
		__start_container policy_agent NODOCKERARGS $POLICY_AGENT_APP_NAME $POLICY_AGENT_EXTERNAL_PORT "/status" "http"
	else
		echo -e $RED"The consul config produced by this test script (filename '<fullpath-to-autotest-dir>.output<file-name>"$ERED
		echo -e $RED"where the file name is the file in the consul_config_app command in this script) must be pointed out by the agent "$ERED
		echo -e $RED"application.yaml"$ERED
		echo -e $RED"The application jar may need to be built beforefor continuing"$ERED
		echo -e $RED"The agent shall now be running on port $POLICY_AGENT_EXTERNAL_PORT for http"$ERED

		read -p "<press any key to continue>"
		__start_container policy_agent "STANDALONE" $POLICY_AGENT_APP_NAME $POLICY_AGENT_EXTERNAL_PORT "/status" "http"
	fi

}

# All calls to the agent will be directed to the agent REST interface from now on
# args: -
# (Function for test scripts)
use_agent_rest_http() {
	echo -e $BOLD"Using agent REST interface with http"$EBOLD
	export ADAPTER=$RESTBASE
	echo ""
}

# All calls to the agent will be directed to the agent REST interface from now on
# args: -
# (Function for test scripts)
use_agent_rest_https() {
	echo -e $BOLD"Using agent REST interface with https"$EBOLD
	export ADAPTER=$RESTBASE_SECURE
	echo ""
	return 0
}

# All calls to the agent will be directed to the agent dmaap interface from now on
# args: -
# (Function for test scripts)
use_agent_dmaap() {
	echo -e $BOLD"Agent using DMAAP interface"$EBOLD
	export ADAPTER=$DMAAPBASE
	echo ""
	return 0
}


# Turn on debug level tracing in the agent
# args: -
# (Function for test scripts)
set_agent_debug() {
	echo -e $BOLD"Setting agent debug"$EBOLD
	curl $LOCALHOST$POLICY_AGENT_EXTERNAL_PORT/actuator/loggers/org.oransc.policyagent -X POST  -H 'Content-Type: application/json' -d '{"configuredLevel":"debug"}' &> /dev/null
	if [ $? -ne 0 ]; then
		__print_err "could not set debug mode" $@
		return 1
	fi
	echo ""
	return 0
}

# Perform curl retries when making direct call to the agent for the specified http response codes
# Speace separated list of http response codes
# args: [<response-code>]*
use_agent_retries() {
	echo -e $BOLD"Do curl retries to the agent REST inteface for these response codes:$@"$EBOLD
	AGENT_RETRY_CODES=$@
	echo ""
	return
}

#################
### Log functions
#################

# Check the agent logs for WARNINGs and ERRORs
# args: -
# (Function for test scripts)

check_policy_agent_logs() {
	__check_container_logs "Policy Agent" $POLICY_AGENT_APP_NAME $POLICY_AGENT_LOGPATH
}

check_control_panel_logs() {
	__check_container_logs "Control Panel" $CONTROL_PANEL_APP_NAME $CONTROL_PANEL_LOGPATH
}

__check_container_logs() {
	dispname=$1
	appname=$2
	logpath=$3
	echo -e $BOLD"Checking $dispname container $appname log ($logpath) for WARNINGs and ERRORs"$EBOLD

	#tmp=$(docker ps | grep $appname)
	tmp=$(docker ps -q --filter name=$appname) #get the container id
	if [ -z "$tmp" ]; then  #Only check logs for running Policy Agent apps
		echo $dispname" is not running, no check made"
		return
	fi
	foundentries="$(docker exec -it $tmp grep WARN $logpath | wc -l)"
	if [ $? -ne  0 ];then
		echo "  Problem to search $appname log $logpath"
	else
		if [ $foundentries -eq 0 ]; then
			echo "  No WARN entries found in $appname log $logpath"
		else
			echo -e "  Found \033[1m"$foundentries"\033[0m WARN entries in $appname log $logpath"
		fi
	fi
	foundentries="$(docker exec -it $tmp grep ERR $logpath | wc -l)"
	if [ $? -ne  0 ];then
		echo "  Problem to search $appname log $logpath"
	else
		if [ $foundentries -eq 0 ]; then
			echo "  No ERR entries found in $appname log $logpath"
		else
			echo -e $RED"  Found \033[1m"$foundentries"\033[0m"$RED" ERR entries in $appname log $logpath"$ERED
		fi
	fi
	echo ""
}

# Store all container logs and other logs in the log dir for the script
# Logs are stored with a prefix in case logs should be stored several times during a test
# args: <logfile-prefix>
# (Function for test scripts)
store_logs() {
	if [ $# != 1 ]; then
		((RES_CONF_FAIL++))
    	__print_err "need one arg, <file-prefix>" $@
		exit 1
	fi
	echo -e $BOLD"Storing all container logs, Policy Agent app log and consul config using prefix: "$1$EBOLD

	docker logs $CONSUL_APP_NAME > $TESTLOGS/$ATC/$1_consul.log 2>&1
	docker logs $CBS_APP_NAME > $TESTLOGS/$ATC/$1_cbs.log 2>&1
	docker logs $POLICY_AGENT_APP_NAME > $TESTLOGS/$ATC/$1_policy-agent.log 2>&1
	docker logs $CONSUL_APP_NAME > $TESTLOGS/$ATC/$1_control-panel.log 2>&1
	docker logs $MR_APP_NAME > $TESTLOGS/$ATC/$1_mr.log 2>&1
	docker logs $CR_APP_NAME > $TESTLOGS/$ATC/$1_cr.log 2>&1
	cp .httplog_${ATC}.txt $TESTLOGS/$ATC/$1_httplog_${ATC}.txt 2>&1

	docker exec -it $SDNC_APP_NAME cat $SDNC_KARAF_LOG> $TESTLOGS/$ATC/$1_SDNC_karaf.log 2>&1

	docker exec -it $SDNC_ONAP_APP_NAME cat $SDNC_ONAP_KARAF_LOG > $TESTLOGS/$ATC/$1_SDNC_ONAP_karaf.log 2>&1

	rics=$(docker ps -f "name=$RIC_SIM_PREFIX" --format "{{.Names}}")
	for ric in $rics; do
		docker logs $ric > $TESTLOGS/$ATC/$1_$ric.log 2>&1
	done
	body="$(__do_curl $LOCALHOST$CBS_EXTERNAL_PORT/service_component_all/$POLICY_AGENT_APP_NAME)"
	echo "$body" > $TESTLOGS/$ATC/$1_consul_config.json 2>&1
	echo ""
}

###############
## Generic curl
###############
# Generic curl function, assumed all 200-codes are ok
# args: <url>
# returns: <returned response (without respose code)>  or "<no-response-from-server>" or "<not found, <http-code>>""
# returns: The return code is 0 for ok and 1 for not ok
__do_curl() {
	echo ${FUNCNAME[1]} "line: "${BASH_LINENO[1]} >> $HTTPLOG
	curlString="curl -skw %{http_code} $1"
	echo " CMD: $curlString" >> $HTTPLOG
	res=$($curlString)
	echo " RESP: $res" >> $HTTPLOG
	http_code="${res:${#res}-3}"
	if [ ${#res} -eq 3 ]; then
  		echo "<no-response-from-server>"
		return 1
	else
		if [ $http_code -lt 200 ] || [ $http_code -gt 299 ]; then
			echo "<not found, resp:${http_code}>"
			return 1
		fi
		if [ $# -eq 2 ]; then
  			echo "${res:0:${#res}-3}" | xargs
		else
  			echo "${res:0:${#res}-3}"
		fi

		return 0
	fi
}

#######################################
### Basic helper function for test cases
#######################################

# Test a simulator container variable value towards target value using an condition operator with an optional timeout.
# Arg: <simulator-name> <host> <variable-name> <condition-operator> <target-value>  - This test is done
# immediately and sets pass or fail depending on the result of comparing variable and target using the operator.
# Arg: <simulator-name> <host> <variable-name> <condition-operator> <target-value> <timeout>  - This test waits up to the timeout
# before setting pass or fail depending on the result of comparing variable and target using the operator.
# If the <variable-name> has the 'json:' prefix, the the variable will be used as url and the <target-value> will be compared towards the length of the json array in the response.
# Not to be called from test script.

__var_test() {
	checkjsonarraycount=0

	if [ $# -eq 6 ]; then
		if [[ $3 == "json:"* ]]; then
			checkjsonarraycount=1
		fi

		#echo -e "---- ${1} sim test criteria: \033[1m ${3} \033[0m ${4} ${5} within ${6} seconds ----"
		echo -e $BOLD"TEST(${BASH_LINENO[1]}): ${1}, ${3} ${4} ${5} within ${6} seconds"$EBOLD
		((RES_TEST++))
		start=$SECONDS
		ctr=0
		for (( ; ; )); do
			if [ $checkjsonarraycount -eq 0 ]; then
				result="$(__do_curl $2$3)"
				retcode=$?
				result=${result//[[:blank:]]/} #Strip blanks
			else
				path=${3:5}
				result="$(__do_curl $2$path)"
				retcode=$?
				echo "$result" > .tmp.curl.json
				result=$(python3 ../common/count_json_elements.py ".tmp.curl.json")
			fi
			duration=$((SECONDS-start))
			echo -ne " Result=${result} after ${duration} seconds${SAMELINE}"
			let ctr=ctr+1
			if [ $retcode -ne 0 ]; then
				if [ $duration -gt $6 ]; then
					((RES_FAIL++))
					#echo -e "----  \033[31m\033[1mFAIL\033[0m - Target ${3} ${4} ${5}  not reached in ${6} seconds, result = ${result} ----"
					echo -e $RED" FAIL${ERED} - ${3} ${4} ${5} not reached in ${6} seconds, result = ${result}"
					return
				fi
			elif [ $4 = "=" ] && [ "$result" -eq $5 ]; then
				((RES_PASS++))
				echo -e " Result=${result} after ${duration} seconds${SAMELINE}"
				echo -e $GREEN" PASS${EGREEN} - Result=${result} after ${duration} seconds"
				#echo -e "----  \033[32m\033[1mPASS\033[0m - Test criteria met in ${duration} seconds ----"
				return
			elif [ $4 = ">" ] && [ "$result" -gt $5 ]; then
				((RES_PASS++))
				echo -e " Result=${result} after ${duration} seconds${SAMELINE}"
				echo -e $GREEN" PASS${EGREEN} - Result=${result} after ${duration} seconds"
				#echo -e "----  \033[32m\033[1mPASS\033[0m - Test criteria met in ${duration} seconds, result = ${result}  ----"
				return
			elif [ $4 = "<" ] && [ "$result" -lt $5 ]; then
				((RES_PASS++))
				echo -e " Result=${result} after ${duration} seconds${SAMELINE}"
				echo -e $GREEN" PASS${EGREEN} - Result=${result} after ${duration} seconds"
				#echo -e "----  \033[32m\033[1mPASS\033[0m - Test criteria met in ${duration} seconds, result = ${result}  ----"
				return
			elif [ $4 = "contain_str" ] && [[ $result =~ $5 ]]; then
				((RES_PASS++))
				echo -e " Result=${result} after ${duration} seconds${SAMELINE}"
				echo -e $GREEN" PASS${EGREEN} - Result=${result} after ${duration} seconds"
				#echo -e "----  \033[32m\033[1mPASS\033[0m - Test criteria met in ${duration} seconds, result = ${result}  ----"
				return
			else
				if [ $duration -gt $6 ]; then
					((RES_FAIL++))
					echo -e $RED" FAIL${ERED} - ${3} ${4} ${5} not reached in ${6} seconds, result = ${result}"
					#echo -e "----  \033[31m\033[1mFAIL\033[0m - Target ${3} ${4} ${5}  not reached in ${6} seconds, result = ${result} ----"
					return
				fi
			fi
			sleep 1
		done
	elif [ $# -eq 5 ]; then
		if [[ $3 == "json:"* ]]; then
			checkjsonarraycount=1
		fi

		#echo -e "---- ${1} sim test criteria: \033[1m ${3} \033[0m ${4} ${5} ----"
		echo -e $BOLD"TEST(${BASH_LINENO[1]}): ${1}, ${3} ${4} ${5}"$EBOLD
		((RES_TEST++))
		if [ $checkjsonarraycount -eq 0 ]; then
			result="$(__do_curl $2$3)"
			retcode=$?
			result=${result//[[:blank:]]/} #Strip blanks
		else
			path=${3:5}
			result="$(__do_curl $2$path)"
			retcode=$?
			echo "$result" > .tmp.curl.json
			result=$(python3 ../common/count_json_elements.py ".tmp.curl.json")
		fi
		if [ $retcode -ne 0 ]; then
			((RES_FAIL++))
			#echo -e "----  \033[31m\033[1mFAIL\033[0m - Target ${3} ${4} ${5} not reached, result = ${result} ----"
			echo -e $RED" FAIL ${ERED}- ${3} ${4} ${5} not reached, result = ${result}"
		elif [ $4 = "=" ] && [ "$result" -eq $5 ]; then
			((RES_PASS++))
			echo -e $GREEN" PASS${EGREEN} - Result=${result}"
			#echo -e "----  \033[32m\033[1mPASS\033[0m - Test criteria met"
		elif [ $4 = ">" ] && [ "$result" -gt $5 ]; then
			((RES_PASS++))
			echo -e $GREEN" PASS${EGREEN} - Result=${result}"
			#echo -e "----  \033[32m\033[1mPASS\033[0m - Test criteria met, result = ${result} ----"
		elif [ $4 = "<" ] && [ "$result" -lt $5 ]; then
			((RES_PASS++))
			echo -e $GREEN" PASS${EGREEN} - Result=${result}"
			#echo -e "----  \033[32m\033[1mPASS\033[0m - Test criteria met, result = ${result} ----"
		elif [ $4 = "contain_str" ] && [[ $result =~ $5 ]]; then
			((RES_PASS++))
			echo -e $GREEN" PASS${EGREEN} - Result=${result}"
			#echo -e "----  \033[32m\033[1mPASS\033[0m - Test criteria met, result = ${result} ----"
		else
			((RES_FAIL++))
			echo -e $RED" FAIL${ERED} - ${3} ${4} ${5} not reached, result = ${result}"
			#echo -e "----  \033[31m\033[1mFAIL\033[0m - Target ${3} ${4} ${5} not reached, result = ${result} ----"
		fi
	else
		echo "Wrong args to __var_test, needs five or six args: <simulator-name> <host> <variable-name> <condition-operator> <target-value> [ <timeout> ]"
		echo "Got:" $@
		exit 1
	fi
}


### Generic test cases for varaible checking

# Tests if a variable value in the CR is equal to a target value and and optional timeout.
# Arg: <variable-name> <target-value> - This test set pass or fail depending on if the variable is
# equal to the target or not.
# Arg: <variable-name> <target-value> <timeout-in-sec>  - This test waits up to the timeout seconds
# before setting pass or fail depending on if the variable value becomes equal to the target
# value or not.
# (Function for test scripts)
cr_equal() {
	if [ $# -eq 2 ] || [ $# -eq 3 ]; then
		__var_test "CR" "$LOCALHOST$CR_EXTERNAL_PORT/counter/" $1 "=" $2 $3
	else
		((RES_CONF_FAIL++))
		__print_err "Wrong args to cr_equal, needs two or three args: <sim-param> <target-value> [ timeout ]" $@
	fi
}

# Tests if a variable value in the MR stub is equal to a target value and and optional timeout.
# Arg: <variable-name> <target-value> - This test set pass or fail depending on if the variable is
# equal to the target or not.
# Arg: <variable-name> <target-value> <timeout-in-sec>  - This test waits up to the timeout seconds
# before setting pass or fail depending on if the variable value becomes equal to the target
# value or not.
# (Function for test scripts)
mr_equal() {
	if [ $# -eq 2 ] || [ $# -eq 3 ]; then
		__var_test "MR" "$LOCALHOST$MR_EXTERNAL_PORT/counter/" $1 "=" $2 $3
	else
		((RES_CONF_FAIL++))
		__print_err "Wrong args to mr_equal, needs two or three args: <sim-param> <target-value> [ timeout ]" $@
	fi
}

# Tests if a variable value in the MR stub is greater than a target value and and optional timeout.
# Arg: <variable-name> <target-value> - This test set pass or fail depending on if the variable is
# greater than the target or not.
# Arg: <variable-name> <target-value> <timeout-in-sec>  - This test waits up to the timeout seconds
# before setting pass or fail depending on if the variable value becomes greater than the target
# value or not.
# (Function for test scripts)
mr_greater() {
	if [ $# -eq 2 ] || [ $# -eq 3 ]; then
		__var_test "MR" "$LOCALHOST$MR_EXTERNAL_PORT/counter/" $1 ">" $2 $3
	else
		((RES_CONF_FAIL++))
		__print_err "Wrong args to mr_greater, needs two or three args: <sim-param> <target-value> [ timeout ]" $@
	fi
}

# Read a variable value from MR sim and send to stdout. Arg: <variable-name>
mr_read() {
	echo "$(__do_curl $LOCALHOST$MR_EXTERNAL_PORT/counter/$1)"
}

# Print a variable value from the MR stub.
# arg: <variable-name>
# (Function for test scripts)
mr_print() {
	if [ $# != 1 ]; then
		((RES_CONF_FAIL++))
    	__print_err "need one arg, <mr-param>" $@
		exit 1
	fi
	echo -e $BOLD"INFO(${BASH_LINENO[0]}): mrstub, $1 = $(__do_curl $LOCALHOST$MR_EXTERNAL_PORT/counter/$1)"$EBOLD
}
