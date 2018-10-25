#!/bin/bash
set -e -x

# Install the ROOT CA
kubectl --context ${ROOTCA} apply -f istio-citadel-standalone.yaml
rootca_host=`kubectl --context ${ROOTCA} get service standalone-citadel -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
# handle case of no LB (ex ICP)
if [[ -z $rootca_host ]]; then
  rootca_host=`kubectl --context ${ROOTCA} get nodes | grep proxy | awk '{print $1}'`
  rootca_port=`kubectl --context ${ROOTCA} get service standalone-citadel -n istio-system -o jsonpath='{.spec.ports[0].nodePort}'`
fi

NAMESPACE="istio-system"
B64_DECODE=${BASE64_DECODE:-base64 --decode}

for CLUSTER in ${CLUSTER1} ${CLUSTER2} #MK#${CLUSTER3}
do
  SERVICE_ACCOUNT=$(echo "istio-citadel-service-account-$CLUSTER" | tr '[:upper:]' '[:lower:]') #lower case to make it valid service account name
  kubectl --context ${ROOTCA} -n istio-system create serviceaccount ${SERVICE_ACCOUNT} || true
  CERT_NAME="istio.${SERVICE_ACCOUNT}"
  DIR="/tmp/ca/${CLUSTER}"
  mkdir -p $DIR

  until kubectl --context ${ROOTCA} get -n ${NAMESPACE} secret ${CERT_NAME}
  do
    echo "waiting for the cert to be generated ..."
    sleep 1
  done

  kubectl --context ${ROOTCA} get -n ${NAMESPACE} secret $CERT_NAME -o jsonpath='{.data.root-cert\.pem}' | $B64_DECODE   > ${DIR}/root-cert.pem
  kubectl --context ${ROOTCA} get -n ${NAMESPACE} secret $CERT_NAME -o jsonpath='{.data.cert-chain\.pem}' | $B64_DECODE  > ${DIR}/cert-chain.pem
  kubectl --context ${ROOTCA} get -n ${NAMESPACE} secret $CERT_NAME -o jsonpath='{.data.key\.pem}' | $B64_DECODE   > ${DIR}/ca-key.pem
  cp ${DIR}/cert-chain.pem ${DIR}/ca-cert.pem

  kubectl --context ${CLUSTER} create secret generic cacerts -n istio-system \
          --from-file=${DIR}/ca-cert.pem --from-file=${DIR}/ca-key.pem \
          --from-file=${DIR}/root-cert.pem --from-file=${DIR}/cert-chain.pem || true

  kubectl --context ${CLUSTER} delete  deployment  -n istio-system  istio-citadel --ignore-not-found
  if [[ -n $rootca_port ]]; then
    sed -e "s/__ROOTCA_HOST__/${rootca_host}/g;s/__ROOTCA_PORT__/${rootca_port}/g" istio-citadel-new-svc-nolb.yaml | kubectl --context ${CLUSTER} apply -f -
  else
    sed -e "s/__ROOTCA_HOST__/${rootca_host}/g" istio-citadel-new-svc-lb.yaml | kubectl --context ${CLUSTER} apply -f -
  fi
  sed -e "s/__SERVICE_ACCOUNT__/${SERVICE_ACCOUNT}/g" istio-citadel.yaml | kubectl --context ${CLUSTER} apply -f -
  kubectl --context ${CLUSTER} apply -f  istio-auto-injection.yaml || true
done
