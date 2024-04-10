#!/bin/bash

# Solicitar configurações do usuário
read -p "Digite o número de núcleos para cada nó do Spark: " spark_node_cores
read -p "Digite a quantidade de memória (em GB) para cada nó do Spark: " spark_node_memory
read -p "Digite a quantidade de memória (em GB) para o MinIO: " minio_memory
read -p "Digite a quantidade de memória (em GB) para o Airflow: " airflow_memory

# Atualizar pacotes
sudo apt-get update

# Instalar dependências
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common

# Instalar Docker
sudo apt-get install -y docker.io
sudo systemctl start docker
sudo systemctl enable docker

# Instalar kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Instalar Minikube
curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube /usr/local/bin/

minikube addons enable ingress

minikube addons enable dns

minikube update-context

# Iniciar Minikube com driver Docker e 12GB de RAM
minikube start --driver=docker --memory=12288 --v=7

# Instalar Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh


# Instalar Spark Operator
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm install my-release spark-operator/spark-operator --namespace spark-operator --create-namespace

# Configurar Spark
cat << EOF > spark-cluster.yaml
apiVersion: "sparkoperator.k8s.io/v1beta2"
kind: SparkApplication
metadata:
  name: spark-pi
  namespace: spark-operator
spec:
  type: Python
  pythonVersion: "3"
  mode: cluster
  image: "openlake/spark-py:3.3.1"
  imagePullPolicy: Always
  mainApplicationFile: local:///opt/spark/examples/src/main/python/pi.py
  sparkVersion: "3.3.1"
  restartPolicy:
    type: OnFailure
    onFailureRetries: 3
    onFailureRetryInterval: 10
    onSubmissionFailureRetries: 5
    onSubmissionFailureRetryInterval: 20
  driver:
    cores: $spark_node_cores
    coreLimit: "2000m"
    memory: "${spark_node_memory}G"
    labels:
      version: "3.3.1"
  executor:
    cores: $spark_node_cores
    instances: 2
    memory: "${spark_node_memory}G"
    labels:
      version: "3.3.1"
EOF

# Instalar MinIO
helm repo remove minio
helm repo add minio https://charts.min.io/
helm repo update
helm install minio minio/minio --namespace minio-system --create-namespace --set rootUser=minio,rootPassword=minio123,resources.requests.memory="${minio_memory}Gi"

# Iniciar MinIO
kubectl port-forward svc/minio --address 0.0.0.0 --namespace minio-system 9000 &

# Instalar Apache Airflow
helm repo add apache-airflow https://airflow.apache.org
helm install airflow apache-airflow/airflow --namespace airflow --create-namespace --set workers.resources.requests.memory="${airflow_memory}Gi"

export MINIKUBE_IP=$(minikube ip)


# Iniciar Spark
clkubectl create -f spark-cluster.yaml --validate=false

# Iniciar Airflow
airflow_pod=$(kubectl get pods --namespace airflow -o jsonpath="{.items[0].metadata.name}")
kubectl exec --namespace airflow -it "$airflow_pod" -- /bin/bash -c "airflow db init && airflow users create --username admin --firstname Peter --lastname Parker --role Admin --email example@example.com && airflow scheduler & airflow webserver --port 8080"

echo "Instalação e inicialização concluídas."