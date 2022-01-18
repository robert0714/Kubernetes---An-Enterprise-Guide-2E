# Chapter 10 Auditing Using Falco, DevOps AI, and ECK
## Deploying Falco

### Import images into containerd in  cluster01-control-plane  docker container
```bash
docker pull   falcosecurity/falco:0.29.1     
docker image save falcosecurity/falco:0.29.1     > falco.tar
docker cp   falco.tar   cluster01-control-plane:/falco.tar
docker exec -it  cluster01-control-plane  bash
ctr image  import falco.tar
ctr image ls
```

```bash
docker pull   falcosecurity/falco:0.30.0
docker image save falcosecurity/falco:0.30.0   > falco-0.30.0.tar
docker cp   falco-0.30.0.tar   cluster01-control-plane:/falco-0.30.0.tar
docker cp   falco-0.30.0.tar   cluster01-worker:/falco-0.30.0.tar
docker exec -it  cluster01-control-plane  ctr image  import  falco-0.30.0.tar
docker exec -it  cluster01-worker  ctr image  import  falco-0.30.0.tar
docker exec -it  cluster01-control-plane  ctr image ls
docker exec -it  cluster01-worker  ctr image ls
```

### Export helm values
```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm search  hub falco  --max-col-width=0
helm show chart  falcosecurity/falco  --version   1.16.3
helm show readme falcosecurity/falco  --version   1.16.3
helm show values falcosecurity/falco  --version   1.16.3   > values-falco-1.16.3.yaml

```