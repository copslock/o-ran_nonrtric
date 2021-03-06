#!/usr/bin/env bash

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

TC_ONELINE_DESCR="Preparation demo setup  - policy management and enrichment information"

#App names to include in the test, space separated list
INCLUDED_IMAGES="CBS CONSUL CP CR MR PA RICSIM SDNC ECS PRODSTUB RC"

#SUPPORTED TEST ENV FILE
SUPPORTED_PROFILES="ONAP-MASTER ORAN-CHERRY"

. ../common/testcase_common.sh $@
. ../common/agent_api_functions.sh
. ../common/ricsimulator_api_functions.sh
. ../common/ecs_api_functions.sh
. ../common/prodstub_api_functions.sh
. ../common/cr_api_functions.sh
. ../common/rapp_catalogue_api_functions.sh

#### TEST BEGIN ####

#Local vars in test script
##########################

use_cr_https
use_agent_rest_https
use_sdnc_https
use_simulator_https
use_ecs_rest_https
use_prod_stub_https
use_rapp_catalogue_http # https not yet supported

if [ "$PMS_VERSION" == "V2" ]; then
    notificationurl=$CR_PATH"/test"
else
   echo "PMS VERSION 2 (V2) is required"
   exit 1
fi

clean_containers

STD_NUM_RICS=2

start_ric_simulators $RIC_SIM_PREFIX"_g3" $STD_NUM_RICS STD_2.0.0

start_mr #Just to prevent errors in the agent log...

start_control_panel

start_sdnc

start_consul_cbs

prepare_consul_config      SDNC  ".consul_config.json"
consul_config_app                  ".consul_config.json"

start_policy_agent

start_rapp_catalogue

start_cr

start_prod_stub

start_ecs

start_rapp_catalogue

set_agent_trace

set_ecs_trace


rapp_cat_api_get_services 200 EMPTY

rapp_cat_api_put_service 201 "Emergency-response-app" v1 "Emergency-response-app" "Emergency-response-app"

rapp_cat_api_get_services 200 "Emergency-response-app" v1 "Emergency-response-app" "Emergency-response-app"

api_get_status 200

# Print the A1 version for STD 2.X
for ((i=1; i<=$STD_NUM_RICS; i++))
do
    sim_print $RIC_SIM_PREFIX"_g3_"$i interface
done
# Load the polictypes in std
for ((i=1; i<=$STD_NUM_RICS; i++))
do
    sim_put_policy_type 201 $RIC_SIM_PREFIX"_g3_"$i STD_QOS_0_2_0 demo-testdata/STD2/sim_qos.json
    sim_put_policy_type 201 $RIC_SIM_PREFIX"_g3_"$i STD_QOS2_0.1.0 demo-testdata/STD2/sim_qos2.json
done

#Check the number of schemas and the individual schemas in STD
api_equal json:policy-types 2 120

for ((i=1; i<=$STD_NUM_RICS; i++))
do
    api_equal json:policy-types?ric_id=$RIC_SIM_PREFIX"_g3_"$i 2 120
done

# Check the schemas in STD
for ((i=1; i<=$STD_NUM_RICS; i++))
do
    api_get_policy_type 200 STD_QOS_0_2_0 demo-testdata/STD2/qos-agent-modified.json
    api_get_policy_type 200 'STD_QOS2_0.1.0' demo-testdata/STD2/qos2-agent-modified.json
done

#Check the number of types
api_equal json:policy-types 2 120

api_put_service 201 "Emergency-response-app" 0 "$CR_PATH/1"

# Create policies in STD
for ((i=1; i<=$STD_NUM_RICS; i++))
do
    generate_uuid
    api_put_policy 201 "Emergency-response-app" $RIC_SIM_PREFIX"_g3_"$i STD_QOS_0_2_0 $((2300+$i)) NOTRANSIENT $notificationurl demo-testdata/STD2/pi1_template.json 1
    generate_uuid
    api_put_policy 201 "Emergency-response-app" $RIC_SIM_PREFIX"_g3_"$i 'STD_QOS2_0.1.0' $((2400+$i)) NOTRANSIENT $notificationurl demo-testdata/STD2/pi1_template.json 1
done


# Check the number of policies in STD
for ((i=1; i<=$STD_NUM_RICS; i++))
do
    sim_equal $RIC_SIM_PREFIX"_g3_"$i num_instances 2
done



FLAT_A1_EI="1"

CB_JOB="$PROD_STUB_HTTPX://$PROD_STUB_APP_NAME:$PROD_STUB_PORT/callbacks/job"
CB_SV="$PROD_STUB_HTTPX://$PROD_STUB_APP_NAME:$PROD_STUB_PORT/callbacks/supervision"
TARGET1="$RIC_SIM_HTTPX://ricsim_g3_1:$RIC_SIM_PORT/datadelivery"
TARGET2="$RIC_SIM_HTTPX://ricsim_g3_2:$RIC_SIM_PORT/datadelivery"

STATUS1="$CR_HTTPX://$CR_APP_NAME:$CR_PORT/callbacks/job1-status"
STATUS2="$CR_HTTPX://$CR_APP_NAME:$CR_PORT/callbacks/job2-status"

prodstub_arm_producer 200 prod-a
prodstub_arm_type 200 prod-a type1
prodstub_arm_job_create 200 prod-a job1
prodstub_arm_job_create 200 prod-a job2


### ecs status
ecs_api_service_status 200



## Setup prod-a
ecs_api_edp_put_producer 201 prod-a $CB_JOB/prod-a $CB_SV/prod-a type1 testdata/ecs/ei-type-1.json

ecs_api_edp_get_producer 200 prod-a $CB_JOB/prod-a $CB_SV/prod-a type1 testdata/ecs/ei-type-1.json

ecs_api_edp_get_producer_status 200 prod-a ENABLED


## Create a job for prod-a
## job1 - prod-a
if [  -z "$FLAT_A1_EI" ]; then
    ecs_api_a1_put_job 201 type1 job1 $TARGET1 ricsim_g3_1 testdata/ecs/job-template.json
else
    ecs_api_a1_put_job 201 job1 type1 $TARGET1 ricsim_g3_1 $STATUS1 testdata/ecs/job-template.json
fi

# Check the job data in the producer
prodstub_check_jobdata 200 prod-a job1 type1 $TARGET1 ricsim_g3_1 testdata/ecs/job-template.json


## Create a second job for prod-a
## job2 - prod-a
if [  -z "$FLAT_A1_EI" ]; then
    ecs_api_a1_put_job 201 type1 job2 $TARGET2 ricsim_g3_2 testdata/ecs/job-template.json
else
    ecs_api_a1_put_job 201 job2 type1 $TARGET2 ricsim_g3_2 $STATUS2 testdata/ecs/job-template.json
fi

# Check the job data in the producer
prodstub_check_jobdata 200 prod-a job2 type1 $TARGET2 ricsim_g3_2 testdata/ecs/job-template.json




check_policy_agent_logs
check_ecs_logs
check_sdnc_logs

#### TEST COMPLETE ####

store_logs          END

print_result
