#!/usr/bin/env bash

set -e

export KUBECONFIG=/home/$SUDO_USER/.kube/config

function exitWithMsg()
{
    # $1 is error code
    # $2 is error message
    echo "Error $1: $2"
    exit $1
}

function clean()
{
    # $1 is error code
    echo "Cleaning up, before exiting..."
    if [[ $(hash k3d) -eq 0 ]]; then
        k3d cluster delete clusterName
        if [ -f $KUBECONFIG ]; then
            sudo chown $SUDO_USER:$SUDO_USER $KUBECONFIG
        fi
        exit $1
    fi
}

trap 'clean $?' ERR SIGINT

if [ $EUID -ne 0 ]; then
    exitWithMsg 1 "Run this as root or with sudo privilege."
fi

basedir=$(cd $(dirname $0) && pwd)

k3dVersion="v5.0.1"
kubectlVersion="v1.22.2"
metallbVersion="v0.10.3"
ingressControllerVersion="v1.0.4"

totalMem=$(free --giga | grep -w Mem | tr -s " "  | cut -d " " -f 2)

usedMem=$(free --giga | grep -w Mem | tr -s " "  | cut -d " " -f 3)

availableMem=$(expr $totalMem - $usedMem)

echo "Available Memory: "$availableMem"Gi"

distroId=$(grep -w DISTRIB_ID /etc/*-release | cut -d "=" -f 2)
distroVersion=$(grep -w DISTRIB_RELEASE /etc/*-release | cut -d "=" -f 2)

echo "Distro: $distroId:$distroVersion"

if [ $availableMem -lt 2 ]; then
    exitWithMsg 1 "Atleast 2Gi of free memory required."
fi

if [ "$distroId" != "Ubuntu" ]; then
    exitWithMsg 1 "Unsupported Distro. This script is written for Ubuntu OS only."
fi

if [ -f $KUBECONFIG ]; then
    sudo chown root:root $KUBECONFIG
fi

echo
read -p "Enter cluster name: " clusterName
read -p "Enter number of worker nodes (0 to 3) (1Gi memory per node is required): " nodeCount
echo

if [[ $nodeCount != ?(-)+([0-9]) ]]; then
    exitWithMsg 1 "$nodeCount is not a number. Number of worker node must be a number"
fi

echo "Checking docker..."
if [[ $(hash docker) -ne 0 ]]; then
    echo "Docker not found. Installing."
    sudo apt-get remove docker docker-engine docker.io containerd runc
    sudo apt install docker.io
    echo "Docker installed."
fi

echo "Checking K3d..."
if [[ $(hash k3d) -ne 0 ]]; then
    echo "K3d not found. Installing."
    curl -s https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=$k3dVersion bash
    echo "K3d installed."
fi

sleep 2

echo
echo "Creating cluster"
echo
k3d cluster create $clusterName --api-port 6550 --agents $nodeCount --k3s-arg "--disable=traefik@server:0" --k3s-arg "--disable=servicelb@server:0" --no-lb --wait --timeout 15m
echo "Cluster $clusterName created."

echo "Checking kubectl..."
if [[ $(hash kubectl) -ne 0 ]]; then
    echo "kubectl not found. Installing."
    curl -LO https://dl.k8s.io/release/$kubectlVersion/bin/linux/amd64/kubectl
    chmod +x kubectl
    sudo mv ./kubectl /usr/local/bin/kubectl
    echo "Kubectl installed."
fi

sleep 2

kubectl cluster-info

if [ $? -ne 0 ]; then
    exitWithMsg 1 "Failed to spinup cluster."
fi

echo
echo "Deploying MetalLB loadbalancer."
echo
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/$metallbVersion/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/$metallbVersion/manifests/metallb.yaml
echo "Waiting for MetalLB to be ready. It may take 10 seconds or more."
kubectl wait --timeout=150s --for=condition=ready pod -l app=metallb,component=controller -n metallb-system
sleep 5

echo "Installing json parser."
sudo apt install jq -y
cidr_block=$(docker network inspect k3d-$clusterName | jq '.[0].IPAM.Config[0].Subnet' | tr -d '"')
base_addr=${cidr_block%???}
first_addr=$(echo $base_addr | awk -F'.' '{print $1,$2,$3,240}' OFS='.')
range=$first_addr/29

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - $range
EOF

echo
echo "Deploying Nginx Ingress Controller."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-$ingressControllerVersion/deploy/static/provider/aws/deploy.yaml
echo "Waiting for Nginx Ingress controller to be ready. It may take 10 seconds or more."
kubectl wait --timeout=150s  --for=condition=ready pod -l app.kubernetes.io/component=controller,app.kubernetes.io/instance=ingress-nginx -n ingress-nginx

sleep 5

echo "Getting Loadbalancer IP"
externalIP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "LoadBalancer IP: $externalIP"

echo
echo "Deploying a sample app."
kubectl apply -f https://raw.githubusercontent.com/navilg/spinup-k8s/master/sample-app.yaml
echo "Waiting for sample application to be ready. It may take 10 seconds or more."
kubectl wait --timeout=150s --for=condition=ready pod -l app=nginx -n sample-app

sleep 5
echo "Sample app is deployed."
sudo chown $SUDO_USER:$SUDO_USER $KUBECONFIG
k3d cluster list

echo
echo
echo "---------------------------------------------------------------------------"
echo "---------------------------------------------------------------------------"
echo "Ingress Load Balancer: $externalIP"
echo "Open sample app in browser: http://$externalIP/sampleapp"
echo "To stop this cluster (If running), run: k3d cluster stop $clusterName"
echo "To start this cluster (If stopped), run: k3d cluster start $clusterName"
echo "To delete this cluster, run: k3d cluster delete $clusterName"
echo "To list all clusters, run: k3d cluster list"
echo "---------------------------------------------------------------------------"
echo "---------------------------------------------------------------------------"
echo
echo "|-- THANK YOU --|"
echo