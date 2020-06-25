#!/usr/bin/env bash

# Assumes you are using dockerhub for kpack
# Assumes you have a dns subdomain hosted in Cloud DNS.

# GCP_PROJECT_NAME='my-project'
# K8S_CLUSTER_NAME='tas4k8s-00'
# REGION='us-central1'
# ZONE='us-central1-c'
# DNS='tas4k8s.domain.cc'
# DNSZONE='tas4k8s' # Zone in GCP (Cloud DNS)

function config_gcloud() {

  if [ ! -z "${GCP_SERVICE_KEY}" ]; then
    echo ${GCP_SERVICE_KEY} > /tmp/creds.json
    gcloud auth activate-service-account --key-file=/tmp/creds.json
    rm -f /tmp/creds.json
  fi
}

function gcp_create_k8s_cluster() {

    gcloud beta container --project "${GCP_PROJECT_NAME}" \
      clusters create "${K8S_CLUSTER_NAME}" \
      --zone "${ZONE}" \
      --no-enable-basic-auth \
      --machine-type "n1-standard-2" \
      --image-type "COS" \
      --disk-type "pd-standard" \
      --disk-size "100" \
      --metadata disable-legacy-endpoints=true \
      --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" \
      --num-nodes "5" \
      --enable-stackdriver-kubernetes --enable-ip-alias \
      --network "projects/${GCP_PROJECT_NAME}/global/networks/default" \
      --subnetwork "projects/${GCP_PROJECT_NAME}/regions/us-central1/subnetworks/default" \
      --default-max-pods-per-node "110" \
      --no-enable-master-authorized-networks \
      --addons HorizontalPodAutoscaling,HttpLoadBalancing \
      --enable-autoupgrade \
      --enable-autorepair
}

function configure_kubectl() {

  # Notes
  # List your curerntly existing clusters
  #  $ gcloud container clusters list
  # switch kubectl contexts

  gcloud container clusters get-credentials ${K8S_CLUSTER_NAME} --zone ${ZONE}  --project ${GCP_PROJECT_NAME}
}

function clone_tas4k8s() {

  sudo git clone https://github.com/cloudfoundry/cf-for-k8s.git
  cd cf-for-k8s && ./hack/generate-values.sh -d ${DNS} > /tmp/cf-values.yml
}

function add_docker_registry() {

  if [ ! -z "$DOCKER_REGISTRY_USER" ]; then
    read -r -p 'Dockerhub Username: ' DOCKER_REGISTRY_USER
  fi

  if [ ! -z "$DOCKER_REGISTRY_PASS" ]; then
    read -rs -p 'Dockerhub Password: ' DOCKER_REGISTRY_PASS
  fi

  cat << EOF >> /tmp/cf-values.yml

app_registry:
   hostname: https://index.docker.io/v1/
   repository: ${DOCKER_REGISTRY_USER}
   username: ${DOCKER_REGISTRY_USER}
   password: ${DOCKER_REGISTRY_PASS}
EOF

}

function deploy_tas() {

  which ytt
  if [ $? != 0 ]; then
    echo "Installing k14s Utils."
    curl -s -L https://k14s.io/install.sh | K14SIO_INSTALL_BIN_DIR=~/bin bash
    export PATH="${PATH}:~/bin"
  fi

  ytt -f config -f /tmp/cf-values.yml > /tmp/cf-for-k8s-rendered.yml
  kapp deploy -a cf -f /tmp/cf-for-k8s-rendered.yml -y
}

function set_dns() {

  INGRESS=$(kubectl get svc -n istio-system istio-ingressgateway|grep -v EXT|awk '{print $4}')
  echo "Set ${DNS} A record to: ${INGRESS}"
  cd hack && bash update-gcp-dns.sh ${DNS} ${DNSZONE}
}

config_gcloud
gcp_create_k8s_cluster
configure_kubectl
clone_tas4k8s
add_docker_registry
deploy_tas
set_dns
