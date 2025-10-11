#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or with sudo"
    exit 1
fi

# A linha abaixo irá chamar nosso novo script "roteador"
source setup-env.sh "$@"

echo "Setup FileSystem"
mkdir -p /opt/5stack/dev
mkdir -p /opt/5stack/demos
mkdir -p /opt/5stack/steamcmd
mkdir -p /opt/5stack/serverfiles
mkdir -p /opt/5stack/timescaledb
mkdir -p /opt/5stack/typesense
mkdir -p /opt/5stack/minio
mkdir -p /opt/5stack/custom-plugins

echo "Environment files setup complete"

curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash

echo "Installing K3s"
curl -sfL https://get.k3s.io | sh -s - --disable=traefik

echo "Installing Ingress Nginx, this may take a few minutes..."
output_redirect kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.2/deploy/static/provider/baremetal/deploy.yaml

while true; do
  PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  if [[ -n "$PODS" ]]; then
    if kubectl wait --namespace ingress-nginx \
      --for=condition=Ready pod \
      --selector=app.kubernetes.io/component=controller \
      --timeout=60s 2>/dev/null; then
      break
    fi
  fi
  sleep 5
done

kubectl label node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') 5stack-api=true 5stack-hasura=true 5stack-minio=true 5stack-timescaledb=true 5stack-redis=true 5stack-typesense=true 5stack-web=true

source update.sh "$@"

echo "Installed 5Stack"