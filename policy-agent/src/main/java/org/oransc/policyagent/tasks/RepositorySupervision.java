/*-
 * ========================LICENSE_START=================================
 * O-RAN-SC
 * %%
 * Copyright (C) 2019 Nordix Foundation
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

package org.oransc.policyagent.tasks;

import java.util.Collection;

import org.oransc.policyagent.clients.A1Client;
import org.oransc.policyagent.clients.A1ClientFactory;
import org.oransc.policyagent.repository.Policies;
import org.oransc.policyagent.repository.PolicyTypes;
import org.oransc.policyagent.repository.Ric;
import org.oransc.policyagent.repository.Ric.RicState;
import org.oransc.policyagent.repository.Rics;
import org.oransc.policyagent.repository.Services;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

/**
 * Regularly checks the exisiting rics towards the local repository to keep it consistent.
 */
@Component
@EnableScheduling
public class RepositorySupervision {
    private static final Logger logger = LoggerFactory.getLogger(RepositorySupervision.class);

    private final Rics rics;
    private final Policies policies;
    private final PolicyTypes policyTypes;
    private final A1ClientFactory a1ClientFactory;
    private final Services services;

    @Autowired
    public RepositorySupervision(Rics rics, Policies policies, A1ClientFactory a1ClientFactory, PolicyTypes policyTypes,
        Services services) {
        this.rics = rics;
        this.policies = policies;
        this.a1ClientFactory = a1ClientFactory;
        this.policyTypes = policyTypes;
        this.services = services;
    }

    /**
     * Regularly contacts all Rics to check if they are alive.
     */
    @Scheduled(fixedRate = 1000 * 60)
    public void checkAllRics() {
        logger.debug("Checking Rics starting");
        createTask().subscribe(this::onRicChecked, this::onError, this::onComplete);
    }

    private Flux<RicData> createTask() {
        synchronized (this.rics) {
            return Flux.fromIterable(rics.getRics()) //
                .flatMap(ric -> createRicData(ric)) //
                .flatMap(ricData -> checkRicState(ricData)) //
                .flatMap(ricData -> checkRicPolicies(ricData)) //
                .flatMap(ricData -> checkRicPolicyTypes(ricData));
        }
    }

    private static class RicData {
        RicData(Ric ric, A1Client a1Client) {
            this.ric = ric;
            this.a1Client = a1Client;
        }

        final Ric ric;
        final A1Client a1Client;
    }

    private Mono<RicData> createRicData(Ric ric) {
        return Mono.just(ric) //
            .flatMap(aRic -> this.a1ClientFactory.createA1Client(ric)) //
            .flatMap(a1Client -> Mono.just(new RicData(ric, a1Client)));
    }

    private Mono<RicData> checkRicState(RicData ric) {
        if (ric.ric.state() == RicState.UNDEFINED) {
            return startRecovery(ric);
        } else if (ric.ric.state() == RicState.RECOVERING) {
            return Mono.empty();
        } else {
            return Mono.just(ric);
        }
    }

    private Mono<RicData> checkRicPolicies(RicData ric) {
        return ric.a1Client.getPolicyIdentities() //
            .onErrorResume(t -> Mono.empty()) //
            .flatMap(ricP -> validateInstances(ricP, ric));
    }

    private Mono<RicData> validateInstances(Collection<String> ricPolicies, RicData ric) {
        synchronized (this.policies) {
            if (ricPolicies.size() != policies.getForRic(ric.ric.name()).size()) {
                return startRecovery(ric);
            }
        }
        for (String policyId : ricPolicies) {
            if (!policies.containsPolicy(policyId)) {
                return startRecovery(ric);
            }
        }
        return Mono.just(ric);
    }

    private Mono<RicData> checkRicPolicyTypes(RicData ric) {
        return ric.a1Client.getPolicyTypeIdentities() //
            .onErrorResume(t -> {
                return Mono.empty();
            }) //
            .flatMap(ricTypes -> validateTypes(ricTypes, ric));
    }

    private Mono<RicData> validateTypes(Collection<String> ricTypes, RicData ric) {
        if (ricTypes.size() != ric.ric.getSupportedPolicyTypes().size()) {
            return startRecovery(ric);
        }
        for (String typeName : ricTypes) {
            if (!ric.ric.isSupportingType(typeName)) {
                return startRecovery(ric);
            }
        }
        return Mono.just(ric);
    }

    private Mono<RicData> startRecovery(RicData ric) {
        RicRecoveryTask recovery = new RicRecoveryTask(a1ClientFactory, policyTypes, policies, services);
        recovery.run(ric.ric);
        return Mono.empty();
    }

    private void onRicChecked(RicData ric) {
        logger.info("Ric: " + ric.ric.name() + " checked");
    }

    private void onError(Throwable t) {
        logger.error("Rics supervision failed", t);
    }

    private void onComplete() {
        logger.debug("Checking Rics completed");
    }

}