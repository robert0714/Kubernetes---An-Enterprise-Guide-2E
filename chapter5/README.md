# Configuring KinD for OpenID Connect
## Addressing the requirements
It work! 
## Configuring your cluster for impersonation
  It does notwork! 
## Configuring Impersonation without OpenUnison
  It does not work! 
## Authenticating from pipelines
[Official Reference](https://openunison.github.io/deployauth/#deploy-the-portal)  
[Official openunison-default.yaml](https://openunison.github.io/assets/yaml/openunison-default.yaml)    
```bash            
helm show values  tremolo/orchestra-login-portal
```
[Other reatled blogs](https://www.tremolosecurity.com/post/pipelines-and-kubernetes-authentication)
 It work! 
 but steps:
1.  Creating Clusters 
```bash
 ./chpter2/create-cluster.sh
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.4.0/aio/deploy/recommended.yaml
kubectl create ns openunison
helm repo add tremolo https://nexus.tremolo.io/repository/helm/
helm repo update
helm install openunison tremolo/openunison-operator --namespace openunison
while [[ $(kubectl get pods -l app=openunison-operator -n openunison -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "waiting for operator pod" && sleep 1; done
kubectl create -f chapter5/myvd-book.yaml
 ``` 
2. Once the operator has been deployed, we need to create a secret that will store passwords used internally by OpenUnison. Make sure to use your own values for the keys in this secret (remember to Base64-encode them):
```bash 
kubectl create -f - <<EOF
apiVersion: v1
type: Opaque
metadata:
   name: orchestra-secrets-source
   namespace: openunison
data:
   K8S_DB_SECRET: c3RhcnQxMjM= 
   unisonKeystorePassword: cGFzc3dvcmQK
   AD_BIND_PASSWORD: c3RhcnQxMjM=
kind: Secret
```
3. To deploy OpenUnison using your openunison-values.yaml file, execute a helm install command that uses the -f option to specify the openunison-values.yaml file:
```bash
 helm install orchestra tremolo/orchestra --namespace openunison -f ./chapter5/openunison-values-20220104.yaml
 helm install orchestra-login-portal tremolo/orchestra-login-portal --namespace openunison -f ./chapter5/openunison-values-20220104.yaml
```
4. The first command extracts OpenUnison's TLS certificate from its secret. This is the same secret referenced by OpenUnison's Ingress object. We use the jq utility to extract the data from the secret and then Base64-decode it:
```bash                   
kubectl get secret ou-tls-certificate -n openunison -o json | jq -r '.data["tls.crt"]' | base64 -d > ou-ca.pem
docker cp ou-ca.pem cluster01-control-plane:/etc/kubernetes/pki/ou-ca.pem
```
5. As we mentioned earlier, to integrate the API server with OIDC, we need to have the OIDC values for the API options. To list the options we will use, describe the api-server-config ConfigMap in the openunison namespace:
```bash                   
kubectl describe configmap api-server-config -n openunison
```
6. Next, edit the API server configuration. OpenID Connect is configured by changing flags on the API server. This is why managed Kubernetes generally doesn't offer OpenID Connect as an option, but we'll cover that later in this chapter. Every distribution handles these changes differently, so check with your vendor's documentation. For KinD, shell into the control plane and update the manifest file:
```bash                   
docker exec -it cluster01-control-plane bash
apt-get update
apt-get install vim
vi /etc/kubernetes/manifests/kube-apiserver.yaml
```
7. Add the flags from the output of the ConfigMap under command. Make sure to add spacing and a dash (-) in front. It should look something like this when you're done:
```bash                   
    - --oidc-issuer-url=https://k8sou.192-168-57-21.nip.io/auth/idp/k8sIdp
    - --oidc-client-id=kubernetes
    - --oidc-username-claim=sub
    - --oidc-groups-claim=groups
    - --oidc-ca-file=/etc/kubernetes/pki/ou-ca.pem
```
Exit vim and the Docker environment (Ctrl + D) and then take a look at the api-server pod:
```bash    
kubectl get pod kube-apiserver-cluster01-control-plane -n kube-system
NAME                                       READY  STATUS       RESTARTS  AGE
kube-apiserver-cluster-auth-control-plane  1/1    Running      0         73s
```
Notice that it's only 73s old. That's because KinD saw that there was a change in the manifest and restarted the API server.
                   
We'll dive into the details of RBAC and authorizations in the next chapter, but for now, create this RBAC binding:
```bash
kubectl create -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
   name: ou-cluster-admins
subjects:
- kind: Group
  name: cn=k8s-cluster-admins,ou=Groups,DC=domain,DC=com 
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF
clusterrolebinding.rbac.authorization.k8s.io/ou-cluster-admins created
```
### Using tokens
```bash
helm install orchestra-token-api chapter5/token-login -n openunison -f chapter5/openunison-values-20220104.yaml
```
Once deployed, we can test using curl:

```bash
export KUBE_AZ=$(curl --insecure -u 'pipeline_svc_account:start123' https://k8sou.192-168-2-114.nip.io/k8s-api-token/token/user | jq -r '.token.id_token')
curl --insecure   -H "Authorization: Bearer $KUBE_AZ"  https://0.0.0.0:6443/api
```
### Using certificates
