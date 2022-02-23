#!/usr/bin/env bash

#
#   Azure Arc K8s conformance test script
#
# Before running the test, create the vars file and fill it:
# $ cp ./.env-platform.sample ./.env-platform
#
# In case your cluster is behind an outbound proxy, please add the following environment variables in the below command
# --plugin-env azure-arc-platform.HTTPS_PROXY="http://<proxy ip>:<proxy port>"
# --plugin-env azure-arc-platform.HTTP_PROXY="http://<proxy ip>:<proxy port>"
# --plugin-env azure-arc-platform.NO_PROXY="kubernetes.default.svc,<ip CIDR etc>"
#
# In case your outbound proxy is setup with certificate authentication, follow the below steps:
# Create a Kubernetes generic secret with the name sonobuoy-proxy-cert with key proxycert in any namespace:
# kubectl create secret generic sonobuoy-proxy-cert --from-file=proxycert=<path-to-cert-file>
# By default we check for the secret in the default namespace. In case you have created the secret in some other namespace, please add the following variables in the sonobuoy run command: 
# --plugin-env azure-arc-platform.PROXY_CERT_NAMESPACE="<namespace of sonobuoy secret>"
# --plugin-env azure-arc-agent-cleanup.PROXY_CERT_NAMESPACE="namespace of sonobuoy secret"

#set -o pipefail
# set -o nounset
#set -o errexit

# Loading variables file
VAR_FILE=./.env-platform
if [[ ! -f ${VAR_FILE} ]]; then
    echo "Unable to find variables file. Have you created it from sample ${VAR_FILE}-sample"
    exit 1
fi
source ${VAR_FILE}

az login --service-principal --username $AZ_CLIENT_ID --password $AZ_CLIENT_SECRET --tenant $AZ_TENANT_ID
az account set -s $AZ_SUBSCRIPTION_ID

declare -g sonobuoyResults
declare -g sonobuoy_done

sonobuoy_done=/tmp/sonobuoy.done

DT_EXEC_TMP="$(date +%Y%m%d%H%M)"
RESULT_DIR="./results-archive-${DT_EXEC_TMP}"
echo ">> Results will be saved on: ${RESULT_DIR}"

# OpenShift debug only: used to collect OCP log when sonobuoy fails with EOF error
collect_sonobuoy_results() {
    sleep 10;
    mkdir ${RESULT_DIR}
    echo "# Finding the node running sonobuoy container"
    local node_pod=$(oc get pods -n sonobuoy sonobuoy -o jsonpath='{.spec.nodeName}')

    echo "# Get containerId and meta"
    local cid_pod=$(oc debug node/$node_pod -- chroot /host /bin/bash -c "crictl ps |grep sonobuoy " 2>/dev/null |awk '{print$1}')

    oc debug node/$node_pod -- chroot /host /bin/bash -c "crictl inspect ${cid_pod}"  2>/dev/null > ${RESULT_DIR}/container-inspect-sonobuoy.json

    echo "# Retrieve results ephemeral storage path on node"
    local volume_path=$(jq -r '.info.runtimeSpec.mounts[] | select(.destination=="/tmp/sonobuoy") |.source' ${RESULT_DIR}/container-inspect-sonobuoy.json)

    echo "# Collect all the results available on container path"
    #mkdir -p results/
    for result_file in $(oc debug node/$node_pod -- chroot /host /bin/bash -c "ls ${volume_path}"  2>/dev/null ); do

        echo "# Collecting file $RESULT";
        oc debug node/$node_pod -- chroot /host /bin/bash -c "cat ${volume_path}/${result_file}" > ${result_file}

        ls -lsha ${result_file}
        sonobuoyResults=${result_file}

        echo "Extracting results...(optional)"
        filename=$(basename -s .tar.gz $result_file)
        mkdir ${RESULT_DIR}/$filename
        tar xf ${result_file}  -C ${RESULT_DIR}/$filename plugins/azure-arc-platform/sonobuoy_results.yaml

        echo "sonobuoy_results was extracted to: ${RESULT_DIR}/$filename/plugins/azure-arc-platform/sonobuoy_results.yaml"
        echo "Show results: "
        cat ${RESULT_DIR}/$filename/plugins/azure-arc-platform/sonobuoy_results.yaml
    done
}

# OpenShift debug only: Patch kube-aad-proxy to allow SCC
patch_kube_aad_proxy() {
  local cnt=0
  local maxRetries=20
  local sleepInter=20
  local deployment_name=kube-aad-proxy
  local ns=azure-arc
  while $(test -z $(oc -n ${ns} get deployment -l app.kubernetes.io/component=${deployment_name} -o jsonpath="{.items[*].metadata.name}"));
  do
    test ${cnt} -eq $maxRetries && return;
    test -f "${sonobuoy_done}" && return;
    let "cnt++";
    echo "#> Waiting for resource deployment/${deployment_name}: $cnt / $maxRetries";
    sleep $sleepInter;
  done
  sleep $sleepInter
  echo "#> Running patch to ${deployment_name}"
  oc \
    patch deployment.apps/${deployment_name} -n ${ns} \
    --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/1/securityContext","value":{"privileged":true,"runAsGroup":0,"runAsUser":0}}]'
}

patch_controller_manager() {
  local cnt=0
  local maxRetries=20
  local sleepInter=20
  local deployment_name=controller-manager
  local ns=azure-arc
  while $(test -z $(oc -n ${ns} get deployment -l app.kubernetes.io/component=${deployment_name} -o jsonpath="{.items[*].metadata.name}"));
  do
    test ${cnt} -eq $maxRetries && return;
    test -f "${sonobuoy_done}" && return;
    let "cnt++";
    echo "#> Waiting for resource deployment/${deployment_name}: $cnt / $maxRetries";
    sleep $sleepInter;
  done
  sleep $sleepInter
  echo "#> Running patch to ${deployment_name}"
  oc \
    patch deployment.apps/${deployment_name} -n ${ns} \
    --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/securityContext","value":{"privileged":true}}]'
}

wait_and_dump_cluster_data() {

  local namespaces_to_test="$1"
  local maxRetries=20
  local sleepInter=10
  local sleepToDump="${sleepToDump:-30}"
  local namespaces_to_dump=""

  # test/wait for NS is created
  for ns in ${namespaces_to_test};
  do
    local resource=""
    local cnt=0
    # those NS takes about 5m after azure-arc is created. arc-k8s-demo is created before
    # cluster-config but almost the same time.
    if [[ "${ns}" == "arc-k8s-demo" ]]; then maxRetries=20; sleepInter=30;
    elif [[ "${ns}" == "cluster-config" ]]; then maxRetries=20; sleepInter=30;
    else maxRetries=5; fi
    while $(test -z ${resource});
    do
      resource=$(oc get ns ${ns} -o jsonpath="{.metadata.name}" 2>/dev/null)
      test ${cnt} -eq $maxRetries && break;
      test -f "${sonobuoy_done}" && break;
      let "cnt++";
      echo "#> Waiting for resource ns/${ns}: $cnt / $maxRetries . CurResults=[${resource}]";
      sleep $sleepInter;
    done
    # if [[ ! -z ${resource} ]]; then
    # forcing dump all
    #namespaces_to_dump+=" ns/${resource}"
    # fi
    test -f "${sonobuoy_done}" && break;
  done

  for ns in ${namespaces_to_test}; do namespaces_to_dump+=" ns/${ns}"; done
  # if [[ -z ${namespaces_to_dump} ]]; then
  #   echo "#> dump: not NS was found to dump [${namespaces_to_dump} ], filling it."
  #   #return
  # fi
  sleep $sleepToDump

  dump_dir=./inspect.local-${dump_name}-${DT_EXEC_TMP}-${arc_platform_version}
  oc adm inspect \
    --dest-dir=${dump_dir} \
    ${namespaces_to_dump}
  echo "Cleaning CLIENT_SECRET from dump..."
  grep -rl $AZ_CLIENT_SECRET ${dump_dir}
  grep -rl $AZ_CLIENT_SECRET ${dump_dir} |xargs sed -i "s/${AZ_CLIENT_SECRET}/[REDACTED]/g"
}

wait_and_dump_cluster_data_base() {
  local namespaces="default sonobuoy azure-arc"
  local dump_name="base"
  local sleepToDump=120
  wait_and_dump_cluster_data "${namespaces}" 
}

wait_and_dump_cluster_data_app() {
  local namespaces="cluster-config arc-k8s-demo"
  local dump_name="app"
  local sleepToDump=30
  wait_and_dump_cluster_data "${namespaces}"
}

# OpenShift debug only: check if provider was created
az_provider_show() {
    az provider show -n Microsoft.Kubernetes -o table;
    az provider show -n Microsoft.KubernetesConfiguration -o table;
    az provider show -n Microsoft.ExtendedLocation -o table ;
}

# OpenShift debug only: required to test elevate cluter privileges like accessing hostPath,
# from conformance test pods. ToDo check how to avoid it.
apply_scc_fixes() {
    # overriding the same of OSD for k8s-conformance: https://github.com/cncf/k8s-conformance/tree/master/v1.22/openshift-dedicated#running-conformance
    oc adm policy add-scc-to-group privileged system:authenticated system:serviceaccounts
    oc adm policy add-scc-to-group anyuid system:authenticated system:serviceaccounts

    oc patch scc restricted \
    --type='json' \
    -p='[{"op": "replace", "path": "/allowHostDirVolumePlugin", "value":true},{"op": "replace", "path": "/allowPrivilegedContainer", "value":true}]'
}
apply_scc_fixes

# OpenShift debug only: force delete all objects (avoid leak from delete subcommand)
clean_up_resources() {
    sonobuoy delete --wait

    # Make all the resources was removed
    oc delete project azure-arc
    oc delete project sonobuoy

    # Those secrets has been leaked on default namespace
    oc delete secret sh.helm.release.v1.azure-arc.v1 -n default
    oc delete secret sh.helm.release.v1.azure-arc.v2 -n default

    #ToDo: delete Azure Arc object from Azure (need it?)
    # Show current AzureArc objects (expected to have 0)
    az_provider_show

    #> Delete
    # for arc_name in $(az connectedk8s list  --resource-group $RESOURCE_GROUP  -o json |jq -r .[].name); do
    #     echo "#> Sending delete command for 'az connectedk8s' for resource ${arc_name}"
    #     az connectedk8s delete --yes --name $arc_name --resource-group $RESOURCE_GROUP ;
    # done

    echo "Sleeping a while after delete process..."
    sleep 30;
}
clean_up_resources

# run the test for each varsion
first_job=true
while read arc_platform_version; do

    if [[ -z $arc_platform_version ]]; then
      # some issues when runing empty lines
      echo "Detect empty version of arc_platform_version, turn down the process"
      break
    fi

    if [[ $first_job != true ]]; then
      # always wait 5m to the next job, not in the last one ;)
      echo "Buffer wait 5 minutes to run the next version[$arc_platform_version]..."
      sleep 5m
    fi
    first_job=false
    echo -e "\n\n>> Running the test suite for Arc for Kubernetes version: ${arc_platform_version}"

    #> Patch to make sure SCC has the less restrictive permissions to run Arc Validation
    #>> removing it for a while to test it in newer versions:
    #>> arck8sconformance.azurecr.io/arck8sconformance/clusterconnect:0.1.7
    #sonobuoy_done=false
    rm -f "${sonobuoy_done}"
    patch_kube_aad_proxy &
    patch_controller_manager &

    wait_and_dump_cluster_data_base &
    wait_and_dump_cluster_data_app &

    sonobuoy run --wait \
    --plugin arc-k8s-platform/platform.yaml \
    --plugin-env azure-arc-platform.TENANT_ID=$AZ_TENANT_ID \
    --plugin-env azure-arc-platform.SUBSCRIPTION_ID=$AZ_SUBSCRIPTION_ID \
    --plugin-env azure-arc-platform.RESOURCE_GROUP=$RESOURCE_GROUP \
    --plugin-env azure-arc-platform.CLUSTER_NAME=$CLUSTERNAME \
    --plugin-env azure-arc-platform.LOCATION=$LOCATION \
    --plugin-env azure-arc-platform.CLIENT_ID=$AZ_CLIENT_ID \
    --plugin-env azure-arc-platform.CLIENT_SECRET=$AZ_CLIENT_SECRET \
    --plugin-env azure-arc-platform.HELMREGISTRY=mcr.microsoft.com/azurearck8s/batch1/stable/azure-arc-k8sagents:$arc_platform_version \
    --plugin arc-k8s-platform/cleanup.yaml \
    --plugin-env azure-arc-agent-cleanup.TENANT_ID=$AZ_TENANT_ID \
    --plugin-env azure-arc-agent-cleanup.SUBSCRIPTION_ID=$AZ_SUBSCRIPTION_ID \
    --plugin-env azure-arc-agent-cleanup.RESOURCE_GROUP=$RESOURCE_GROUP \
    --plugin-env azure-arc-agent-cleanup.CLUSTER_NAME=$CLUSTERNAME \
    --plugin-env azure-arc-agent-cleanup.CLEANUP_TIMEOUT=$CLEANUP_TIMEOUT \
    --plugin-env azure-arc-agent-cleanup.CLIENT_ID=$AZ_CLIENT_ID \
    --plugin-env azure-arc-agent-cleanup.CLIENT_SECRET=$AZ_CLIENT_SECRET \
    --plugin-env azure-arc-platform.OBJECT_ID=$AZ_OBJECT_ID \
    --config config.json \
    --dns-namespace="${DNS_NAMESPACE}" \
    --dns-pod-labels="${DNS_POD_LABELS}"

    touch "${sonobuoy_done}"
    sleep 30
    echo "Test execution completed..Retrieving results"

    sonobuoyResults=$(sonobuoy retrieve)
    sonobuoy results $sonobuoyResults

    #>>>> Patch to remove secretes starts here
    # OpenShift collector when 'sonobuoy retrieve' fails with 'EOF'
    test -z $sonobuoyResults && collect_sonobuoy_results

    # backup current results
    res_filename="$(basename -s .tar.gz $sonobuoyResults)"
    cp -v $sonobuoyResults "${res_filename}-bkp.tar.gz"

    # clean secrets (1): the original file will be overrided
    res_tmp="./testResult"
    mkdir -p ${res_tmp}
    python ../arc-k8s-platform/remove-secrets.py $sonobuoyResults ${res_tmp}
    rm -rf ${res_tmp}

    # clean secret (2)
    res_tmp="./testResult"
    mkdir -p ${res_tmp}
    tar xfz $sonobuoyResults -C ${res_tmp}
    echo "# Reporting files with credential AZ_CLIENT_SECRET: "
    grep -rl $AZ_CLIENT_SECRET ${res_tmp}

    echo "# Redacting credential AZ_CLIENT_SECRET: "
    grep -rl $AZ_CLIENT_SECRET ${res_tmp} |xargs sed -i "s/${AZ_CLIENT_SECRET}/[REDACTED]/g"

    rm -vf $sonobuoyResults
    res_cwd=$PWD
    pushd ${res_tmp}
    # Will be the new $sonobuoyResults
    tar cfz "${res_cwd}/$sonobuoyResults" *
    popd
    rm -rf ${res_tmp}
    #mv -v ${res_cwd}/${res_filename}* ${RESULT_DIR}

    #>>>> Patch to remove secretes ends here

    # from original:
    mkdir results
    mv $sonobuoyResults results/$sonobuoyResults
    cp partner-metadata.md results/partner-metadata.md
    tar -czvf conformance-results-$arc_platform_version.tar.gz results
    rm -rf results

    echo "Publishing results.."

    IFS='.'
    read -ra version <<< $arc_platform_version
    containerString="conformance-results-major-${version[0]}-minor-${version[1]}-patch-${version[2]}"
    IFS=$' \t\n'

    mkdir ${containerString}
    cp -vf conformance-results-$arc_platform_version.tar.gz ${containerString}/conformance-results-$OFFERING_NAME.tar.gz

    az storage container create \
        -n $containerString \
        --account-name $AZ_STORAGE_ACCOUNT \
        --sas-token $AZ_STORAGE_ACCOUNT_SAS
    az storage blob upload \
       --file conformance-results-$arc_platform_version.tar.gz \
       --name conformance-results-$OFFERING_NAME.tar.gz \
       --container-name $containerString \
       --account-name $AZ_STORAGE_ACCOUNT \
       --sas-token $AZ_STORAGE_ACCOUNT_SAS

    echo "Cleaning the cluster... (ignoring for now)"
    clean_up_resources

done < aak8sSupportPolicy.txt

echo "#> The results was upload to Blob storage and saved locally to this path: ./conformance-results-*"
for res_dir in $(ls -d conformance-results-*/);
do
    echo "#>> listing dir ${res_dir}:"
    ls -l ${res_dir}/
done
