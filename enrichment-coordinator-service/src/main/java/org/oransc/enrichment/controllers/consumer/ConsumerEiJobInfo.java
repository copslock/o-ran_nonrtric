/*-
 * ========================LICENSE_START=================================
 * O-RAN-SC
 * %%
 * Copyright (C) 2020 Nordix Foundation
 * %%
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * ========================LICENSE_END===================================
 */

package org.oransc.enrichment.controllers.consumer;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.google.gson.annotations.SerializedName;

import io.swagger.annotations.ApiModel;
import io.swagger.annotations.ApiModelProperty;

import org.immutables.gson.Gson;

@Gson.TypeAdapters
@ApiModel(value = "EiJobObject", description = "Information for an Enrichment Information Job")
public class ConsumerEiJobInfo {

    @ApiModelProperty(value = "EI type Idenitifier of the EI job", required = true)
    @SerializedName("eiTypeId")
    @JsonProperty(value = "eiTypeId", required = true)
    public String eiTypeId;

    @ApiModelProperty(value = "Identity of the owner of the job", required = true)
    @SerializedName("jobOwner")
    @JsonProperty(value = "jobOwner", required = true)
    public String owner;

    @ApiModelProperty(value = "EI type specific job data", required = true)
    @SerializedName("jobDefinition")
    @JsonProperty(value = "jobDefinition", required = true)
    public Object jobData;

    @ApiModelProperty(value = "The target URI of the EI data", required = true)
    @SerializedName("jobResultUri")
    @JsonProperty(value = "jobResultUri", required = true)
    public String targetUri;

    @ApiModelProperty(value = "The target of EI job status notifications", required = false)
    @SerializedName("jobStatusNotificationUri")
    @JsonProperty(value = "jobStatusNotificationUri", required = false)
    public String statusNotificationUri;

    public ConsumerEiJobInfo() {
    }

    public ConsumerEiJobInfo(String eiTypeId, Object jobData, String owner, String targetUri,
        String statusNotificationUri) {
        this.eiTypeId = eiTypeId;
        this.jobData = jobData;
        this.owner = owner;
        this.targetUri = targetUri;
        this.statusNotificationUri = statusNotificationUri;
    }
}
