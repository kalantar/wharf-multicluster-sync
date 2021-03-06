#!/bin/bash
set -o errexit

#AGENT_NS=default
AGENT_NS=istio-system
INTERMESH_PORT=31444

if ! [ -z "$3" ]; then
    echo "Unimplemented: Create config map for multiple services. Use one peer for now."
    exit 1
fi

if [ -z "$CONNECTION_MODE" ]
  then
	CONNECTION_MODE=live
    echo "Remote Service Bindings will be created as $CONNECTION_MODE"
  else
    echo "Using CONNECTION_MODE=$CONNECTION_MODE"
fi

CLIENT_CLUSTER=$1
CLIENT_ID=$(echo $CLIENT_CLUSTER | cut -f1 -d=)
CLIENT_NAME=$(echo $CLIENT_CLUSTER | cut -f2 -d=)
if [ -z "$CLIENT_NAME" ]; then
	CLIENT_NAME=$CLIENT_CLUSTER
else
	echo $CLIENT_NAME will have role $CLIENT_ID
fi

CLIENT_PORT=80
CLIENT_IP=`kubectl --context ${CLIENT_NAME} get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
# handle case of no LB (ex ICP)
if [[ -z $CLIENT_IP ]]; then
  CLIENT_IP=`kubectl --context ${CLIENT_NAME} get nodes | grep proxy | awk '{print $1}'`
  CLIENT_PORT=`kubectl --context ${CLIENT_NAME} get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[0].nodePort}'`
fi
shift
kubectl --context ${CLIENT_NAME} patch service istio-ingressgateway -n istio-system --type=json --patch='[{"op": "add", "path": "/spec/ports/0", "value": {"name": "tls-intermesh", "port": '$INTERMESH_PORT', "nodePort": '$INTERMESH_PORT', "targetPort": '$INTERMESH_PORT'}}]'

if [ "$#" -eq 0 ]; 
then
  PEERS="WatchedPeers: []"
else
# TODO Create SERVER_IP as list so we can create ConfigMap with list of peers
for SERVER_CLUSTER in "$@"
do
	SERVER_ID=$(echo $SERVER_CLUSTER | cut -f1 -d=)
	SERVER_NAME=$(echo $SERVER_CLUSTER | cut -f2 -d=)
	if [ -z "$SERVER_NAME" ]; then
		SERVER_NAME=$SERVER_CLUSTER
	else
		echo $SERVER_NAME will have role $SERVER_ID
	fi

        SERVER_PORT=80
	SERVER_IP=`kubectl --context ${SERVER_NAME} get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
        # handle case of no LB (ex ICP)
        SERVER_AGENT_PORT=8999
        if [[ -z $SERVER_IP ]]; then
          SERVER_IP=`kubectl --context ${SERVER_NAME} get nodes | grep proxy | awk '{print $1}'`
          SERVER_PORT=`kubectl --context ${SERVER_NAME} get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[0].nodePort}'`
          SERVER_AGENT_PORT=`kubectl --context ${SERVER_NAME} get service istio-ingressgateway -n istio-system -o json | jq '.spec.ports[] | select(.port==80).nodePort'
        fi
	# SERVER_AGENT_IP=`kubectl --context ${SERVER_NAME} get service mc-agent -n "$AGENT_NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
	SERVER_AGENT_IP=$SERVER_IP
	echo $CLIENT_NAME \($CLIENT_ID\) is a client of $SERVER_NAME \($SERVER_ID\) with Ingress Gateway at $SERVER_IP
done

  PEERS=$(cat <<-END
WatchedPeers:
      - ID: $SERVER_ID
        GatewayIP: $SERVER_IP
        GatewayPort: $INTERMESH_PORT
        AgentIP: $SERVER_AGENT_IP
        AgentPort: $SERVER_AGENT_PORT
        ConnectionMode: $CONNECTION_MODE
END
)
fi

# Create ConfigMap to configure agent
set +e
cat <<EOF | kubectl --context $CLIENT_NAME apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mc-configuration
  namespace: istio-system
  labels:
    istio: multi-cluster-agent
data:
  config.yaml: |
      ID: $CLIENT_ID
      GatewayIP: $CLIENT_IP
      GatewayPort: $INTERMESH_PORT
      AgentPort: 8999
      TrustedPeers:
      - "*"
      $PEERS
EOF
set -e
	
# Deploy the MC agent service
kubectl --context $CLIENT_NAME apply -f deploy.yaml
