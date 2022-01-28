# Provisioning a Platform
Every chapter in this book, up until this point, has focused on the infrastructure of your cluster. We have explored how to deploy Kubernetes, how to secure it, and how to monitor it. What we haven't talked about is how to deploy applications.

In this, our final chapter, we're going to work on building an application deployment platform using what we've learned about Kubernetes. We're going to build our platform based on some common enterprise requirements. Where we can't directly implement a requirement, because building a platform on Kubernetes can fill its own book, we'll call it out and provide some insights.

In this chapter, we will cover the following topics:
 
* Preparing our cluster
* Deploying GitLab
* Deploying Tekton
* Deploying ArgoCD
* Automating project onboarding using OpenUnison

You'll have a good starting point for building out you own GitOps platform on Kubernetes by the end of this chapter. It's not designed for production use, but should get you well on your way.
## Technical requirements
To perform the exercises in this chapter, you will need a clean KinD cluster with a minimum of 16 GB of memory, 75 GB storage, and 4 CPUs. The system we will build is minimalist but still requires considerable horsepower to run.

If you're using the KinD cluster from this book, start with a new cluster. We're deploying several components that need to be integrated and it will be simpler and easier to start fresh rather than potentially struggling with previous configurations. 
```bash
cd /chapter2
./create-cluster.sh
```
## Preparing our cluster
Before we start deploying the applications that will make up our stack, we're going to deploy ***JetStack's cert-manager*** to automate certificate issuing, a simple container registry, and OpenUnison for authentication and automation.

Before creating your cluster, let's generate a root certificate for our **certificate authority (CA)** and make sure our host trusts it. This is important so that we can push a sample container without worrying about trust issues:

1. Create a self-signed certificate that we'll use as our CA. The **chapter14/shell** directory of the Git repository for this book contains a script called **makeca.sh** that will generate this certificate for you:
```bash
cd chapter14/shell/
sh ./makeca.sh

Generating RSA private key, 2048 bit long modulus (2 primes)
.............................................................................................................................................+++++
....................+++++
e is 65537 (0x010001)
```
You'll see the  **chapter14/shell/ssl** directory is generated.
2. Trust the CA certificate on your local VM where you're deploying KinD. Assuming you're using Ubuntu 20.04:
```bash
cd chapter14/shell/ssl/
sudo cp tls.crt /usr/local/share/ca-certificates/internal-ca.crt
sudo cp tls.crt /usr/share/ca-certificates/internal-ca.crt  (maybee ommit....)
sudo echo "internal-ca.crt" >> /etc/ca-certificates.conf  (maybee ommit....)
sudo update-ca-certificates
sudo reboot
```
The Objective is that you execute command about docker push or pull.

or refer[ How to Add Self-Sign Certificate Authority to Your Browsers](https://dchan.tech/security/how-to-add-self-sign-certificate-authority-to-your-browsers/)

Once your VM is back, deploy a fresh cluster by running **chapter2/create-cluster.sh**.

Once done, wait for the pods to finish running before moving on to deploying **cert-manager**.

### Deploying cert-manager
JetStack, a Kubernetes-focused consulting company, created a project called ***cert-manager*** to make it easier to automate the creation and renewal of certificates. This project works by letting you define issuers using Kubernetes custom resources and then using annotations on ***Ingress*** objects to generate certificates using those issuers. The end result is a cluster running with properly managed and rotated certificates without generating a single **certificate signing request (CSR)** or worrying about expiration!

The **cert-manager** project is most often mentioned with ***Let's Encrypt*** (https://letsencrypt.org/) to automate the publishing of certificates that have been signed by a commercially recognized certificate authority for free (as in beer). This is possible because ***Let's Encrypt*** automates the process. The certificates are only good for 90 days and the entire process is API-driven. In order to drive this automation, you must have some way of letting ***Let's Encrypt*** verify ownership of the domain you are trying to get a certificate for. Throughout this book, we have used **nip.io** to simulate a DNS. If you have a DNS service that you can use and is supported by **cert-manager**, such as Amazon's Route 53, then this is a great solution.

Since we're using **nip.io**, we will deploy **cert-manager** with a self-signed certificate authority. This gives us the benefit of having a certificate authority that can quickly generate certificates without having to worry about domain validation. We will then instruct our workstation to trust this certificate as well as the applications we deploy so that everything is secured using properly built certificates.

> **⚠ ATTENTION:**  
> Using a self-signed certificate authority is a common practice for most enterprises for internal deployments. This avoids having to deal with potential validation issues where a commercially signed certificate won't provide much value. Most enterprises can distribute an internal certificate authority's certificates via their Active Directory infrastructure. Chances are your enterprise has a way to request either an internal certificate or a wildcard that could be used too.

The steps to deploy **cert-manager** are as follows:

1. From your cluster, deploy the cert-manager manifests:
```bash
$ kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
```
2. There is now an SSL directory with a certificate and a key. The next step is to create a secret from these files that will become our certificate authority:
```bash
$ cd chapter14/shell/ssl/
$ kubectl -n cert-manager create secret tls ca-key-pair --key=./tls.key --cert=./tls.crt

secret/ca-key-pair  created
```
3. Next, create the **ClusterIssuer** object so that all of our **Ingress** objects can have properly minted certificates:
```bash
$ cd ../../yaml/
$ kubectl create -f ./certmanager-ca.yaml

clusterissuer.cert-manager.io/ca-issuer created
```
4. With **ClusterIssuer** created, any **Ingress** object with the **cert-manager.io/cluster-issuer: "ca-issuer"** annotation will have a certificate signed by our authority created for them. One of the components we will be using for this is our container registry. Kubernetes uses Docker's underlying mechanisms for pulling containers, and KinD will not pull images from registries running without TLS or using an untrusted certificate. To get around this issue, we need to import our certificate into both our worker and nodes:
```bash
$ cd ~/
$ kubectl get secret ca-key-pair -n cert-manager -o json | jq -r '.data["tls.crt"]' | base64 -d > internal-ca.crt
$ docker cp internal-ca.crt cluster01-worker:/usr/local/share/ca-certificates/internal-ca.crt
$ docker exec -ti cluster01-worker update-ca-certificates

Updating certificates in /etc/ssl/certs...
1 added, 0 removed; done.
Running hooks in /etc/ca-certificates/update.d...
done.

$ docker restart cluster01-worker
```
At this point, wait for **cluster01-worker** to finish restarting. Also, wait for all the pods in the cluster to come back:
```bash
$ docker cp internal-ca.crt cluster01-control-plane:/usr/local/share/ca-certificates/internal-ca.crt
$ docker exec -ti cluster01-control-plane update-ca-certificates

Updating certificates in /etc/ssl/certs...
1 added, 0 removed; done.
Running hooks in /etc/ca-certificates/update.d...
done.

$ docker restart cluster01-control-plane
```

The first command extracts the certificate from the secret we created to host the certificate. The next set of commands copies the certificate to each container, instructs the container to trust it, and finally, restarts the container. Once your containers are restarted, wait for all the Pods to come back; it could take a few minutes.

> **⚠ ATTENTION:**
> Now would be a good time to download **internal-ca.crt**; install it onto your local workstation and potentially into your browser of choice. Different operating systems and browsers do this differently, so check the appropriate documentation on how to do this. Trusting this certificate will make things much easier when interacting with applications, pushing containers, and using command-line tools.

With **cert-manager** ready to issue certificates and both your cluster and your workstation trusting those certificates, the next step is to deploy a container registry.

### Deploying the Docker container registry
Docker, Inc. provides a simple registry. There is no security on this registry, so it is most certainly not a good option for production use. The **chapter14/docker-registry/docker-registry.yaml** file will deploy the registry for us and create an **Ingress** object. The **chapter14/docker-registry/deploy-docker-registry.sh** script will deploy the registry for you:
```bash
$ ./deploy-docker-registry.sh
namespace/docker-registry created
k8spsphostfilesystem.constraints.gatekeeper.sh/docker-registry-host-filesystem unchanged
statefulset.apps/docker-registry created
service/docker-registry created
ingress.networking.k8s.io/docker-registry created 
```
Once the registry is running, you can try accessing it from your browser.
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
echo  https://docker.apps.$hostip.nip.io
```
open url https://docker.apps.$hostip.nip.io in browser


You won't see much since the registry has no web UI, but you also shouldn't get a certificate error. That's because we deployed **cert-manager** and are issuing signed certificates! With our registry running, we'll deploy OpenUnison and GateKeeper.

You have better to test.
```bash
docker pull busybox
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
docker tag busybox   docker.apps.$hostip.nip.io/busybox
docker push   docker.apps.$hostip.nip.io/busybox

curl -X GET https://docker.apps.$hostip.nip.io/v2/_catalog

{"repositories":["busybox"]}
```

[Official Reference] (https://docs.docker.com/registry/insecure/)

> Deploy a plain HTTP registry
Edit the **daemon.json** file, whose default location is /etc/docker/daemon.json on Linux
If the daemon.json file does not exist, create it. Assuming there are no other settings in the file, it should have the following contents:
```json
{
  "insecure-registries" : ["docker.apps.$hostip.nip.io:5000"]
}
```

> Use self-signed certificates
```bash 
sudo mkdir -p /etc/docker/certs.d/docker.apps.$hostip.nip.io:5000

openssl req \
  -newkey rsa:4096 -nodes -sha256 -keyout ca.key \
  -addext "subjectAltName = DNS:docker.apps.$hostip.nip.io" \
  -x509 -days 365 -out ca.crt
  
sudo cp ca.crt  /etc/docker/certs.d/docker.apps.$hostip.nip.io:5000/ca.crt

sudo cp ca.crt   /usr/local/share/ca-certificates/docker.apps.$hostip.nip.io.crt

pdate-ca-certificates
```

### Deploying OpenUnison and GateKeeper
In ***Chapter 5, Integrating Authentication into Your Cluster***, we introduced OpenUnison to authenticate access to our KinD deployment. OpenUnison comes in two flavors. The first, which we have had deployed in earlier chapters' examples, is a login portal that lets us authenticate using a central source and pass group information to our RBAC policies. The second, which we'll deploy in this chapter, is a **Namespace as a Service (NaaS)** portal that we'll use as the basis for integrating the systems that will manage our pipeline. This portal will also give us a central UI for requesting projects to be created and managing access to our project's systems.

We defined the fact that each project we deploy will have three "roles" that will span several systems. Will your enterprise let you create and manage groups for every project we create? Some might, but Active Directory is a critical component in most enterprises, and write access can be difficult to get. It's unlikely that the people who run your Active Directory are the same people who you report to when managing your cluster, complicating your ability to get an area of Active Directory that you have administrative rights in. The OpenUnison NaaS portal lets you manage access with local groups that can be easily queried, just like with Active Directory, but you have the control to manage them.

To facilitate OpenUnison's automation capabilities, we need to deploy a database to store persistent data and an SMTP server to notify users when they have open requests or when requests have been completed. For the database, we'll deploy the open source MariaDB. For a **Simple Mail Transfer Protocol (SMTP)** (email) server, most enterprises have very strict rules about sending emails. We don't want to have to worry about getting email set up for notifications, so we'll run a "black hole" email service that just disregards all SMTP requests.

Don't worry about having to go back through previous chapters to get OpenUnison and GateKeeper up and running. We created two scripts to build everything out for you:
```bash
$ .
$ ./deploy_gatekeeper.sh
.
.
.
$ cd ../openunison
$ ./deploy_openunison_imp.sh
.
.
.

OpenUnison is deployed!
```

It will take a few minutes, but once done, your environment will be ready for the next step. We'll be using OpenUnison for SSO with GitLab and ArgoCD so we want to have it ready to go. We'll come back to OpenUnison later in the chapter as we deploy the integration of our platform components. With your cluster prepared, the next step is to deploy the components for our pipeline.

## Deploying GitLab
When building a GitOps pipeline, one of the most important components is a Git repository. GitLab has many components besides just Git, including a UI for navigating code, a web-based **integrated development environment (IDE)** for editing code, and a robust identity implementation to manage access to projects in a multi-tenant environment. This makes it a great solution for our platform since we can map our "roles" to GitLab groups.

In this section, we're going to deploy GitLab into our cluster and create two simple repositories that we'll use later when we deploy Tekton and ArgoCD. We'll focus on the automation steps when we revisit OpenUnison to automate our pipeline deployments.

GitLab deploys with a Helm chart. For this book, we built a custom **values** file to run a minimal install. While GitLab comes with features that are similar to ArgoCD and Tekton, we won't be using them. We also didn't want to worry about high availability. Let's begin:

1. Create a new namespace called **gitlab**:
```bash
$ kubectl create ns gitlab
namespace/gitlab created
```

2. We need to add our certificate authority as a secret for GitLab to trust talking to OpenUnison and the webhooks we will eventually create for Tekton:
```bash
$ mkdir /tmp/gitlab-secret
$ kubectl get secret ca-key-pair \
  -n cert-manager -o json | jq -r '.data["tls.crt"]' \
  | base64 -d > /tmp/gitlab-secret/tls.crt
$ kubectl create secret generic \
  internal-ca --from-file=/tmp/gitlab-secret/ -n gitlab
```

3. Deploy a Secret for GitLab that configures its OpenID Connect provider to use OpenUnison for authentication:
```bash
$ cd chapter14/gitlab/sso-secret
$ ./deploy-gitlab-secret.sh
secret/gitlab-oidc created
```

4. This **Secret** needs to be created before deploying the Helm chart because, just as with OpenUnison, you shouldn't keep secrets in your charts, even if they're encrypted. Here's what the base64-decoded data from the secret will look like once created:
```yaml
// kubectl -n gitlab get secret gitlab-oidc -o json | jq -r '.data.provider' |base64 -d
name: openid_connect
label: OpenUnison
args:
  name: openid_connect
  scope:
    - openid
    - profile
  response_type: code
  issuer: https://k8sou.apps.192-168-18-24.nip.io/auth/idp/k8sIdp
  discovery: true
  client_auth_method: query
  uid_field: sub
  send_scope_to_token_endpoint: false
  client_options:
    identifier: gitlab
    secret: secret
    redirect_uri: https://gitlab.apps.192-168-18-24.nip.io/users/auth/openid_connect/callback
```

> **⚠ ATTENTION:**
> We're using a client secret of secret. This should not be done for a production cluster. If you're deploying GitLab into production using our templates as a starting point, make sure to change this.

5. If your cluster is running on a single VM, now would be a good time to create a snapshot. If something goes wrong during the GitLab deployment, it's easier to revert back to a snapshot since the Helm chart doesn't do a great job of cleaning up after itself on a delete.

6. Add the chart to your local repository and deploy GitLab:
```bash
$ cd chapter14/gitlab/helm

$ ./gen-helm-values.sh

$ helm repo add gitlab https://charts.gitlab.io
  "gitlab" has been added to your repositories
$ helm repo update
$ helm install gitlab gitlab/gitlab -n gitlab -f /tmp/gitlab-values.yaml
NAME: gitlab
LAST DEPLOYED: Mon Sep 27 14:00:44 2021
NAMESPACE: gitlab
STATUS: deployed
REVISION: 1
```

7. It will take a few minutes to run. Even once the Helm chart has been installed, it can take 15–20 minutes for all the Pods to finish deploying.

8. We next need to update our GitLab shell to accept SSH connections on port 2222. This way, we can commit code without having to worry about blocking SSH access to your KinD server. Run the following to patch the Deployment:
```bash
kubectl patch deployments gitlab-gitlab-shell -n gitlab -p '{"spec":{"template":{"spec":{"containers":[{"name":"gitlab-shell","ports":[{"containerPort":2222,"protocol":"TCP","name":"ssh","hostPort":2222}]}]}}}}'
```

9. Once the Pod relaunches, you'll be able to SSH to your GitLab hostname on port **2222**.

10. To get your root password to log in to GitLab, get it from the secret that was generated:
```bash
$ kubectl get secret gitlab-gitlab-initial-root-password -o json -n gitlab | jq -r '.data.password' | base64 -d

9gYzg3zeDyNLS4Zshyjpko9wVQ53fvBFpGTjsXubVWYkNSxlX8xpeEm3uipj1Jsb
```

You now can log in to your GitLab instance by going to **https://gitlab.apps.x-x-x-x.nip.io**, where ***x-x-x-x*** is the IP of your server. 

```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
echo  https://gitlab.apps.$hostip.nip.io
```
Since my server is running on 192.168.18.24, my GitLab instance is running on https://gitlab.apps.192-168-18-24.nip.io/.

#### Creating example projects
To explore Tekton and ArgoCD, we will create two projects. One will be for storing a simple Python web service, while the other will store the manifests for running the service. Let's deploy these projects:

1. You'll need to upload an SSH public key. To interact with GitLab's Git repositories, we're going to be centralizing authentication via OpenID Connect. GitLab won't have a password for authentication. To upload your SSH public key, click on your user icon in the upper right-hand corner, and then click on the **SSH Keys** menu on the left-hand task bar. Here you can paste your SSH public key.[referecnce](https://docs.gitlab.com/ee/ssh/)
```bash
ssh-keygen -t rsa -b 2048
```
To set ~/.ssh/config (Not required)
```config
## ~/.ssh/config
Host gitlab.apps.192-168-18-24.nip.io
  PreferredAuthentications publickey
  IdentityFile ~/.ssh/id_rsa
```
Verify that your SSH key was added correctly.
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
ssh -T git@gitlab.apps.$hostip.nip.io -p 2222
ssh -T git@gitlab.apps.192-168-18-24.nip.io -p 2222
```
2. Create a project and call it **hello-python**. Keep the visibility private.
3. Clone the project using SSH. Because we're running on port **2222**, we need to change the URL provided by GitLab to be a proper SSH URL. For instance, my GitLab instance gives me the URL **git@gitlab.apps.192-168-18-24.nip.io:root/hello-python.git**. This needs to be changed to **ssh://git@gitlab.apps.192-168-18-24.nip.io:2222/root/hello-python.git**.
```bash
git clone  ssh://git@gitlab.apps.192-168-18-24.nip.io:2222/root/hello-python.git
```

4. Once cloned, copy the contents of **chapter14/python-hello** into your repository and push to GitLab:
```bash
$ cd chapter14/example-apps/python-hello
$ git archive --format=tar HEAD > /path/to/hello-python/data.tar
$ cd /path/to/hello-python
$ tar -xvf data.tar
README.md
source/
source/Dockerfile
source/helloworld.py
source/requirements.txt
$ rm data.tar
$ git add *
$ git commit -m 'initial commit'
$ git push
```
5. In GitLab, create another project called ***hello-python-operations*** with visibility set to **private**. Clone this project, copy the contents of **chapter14/example-apps/python-hello-operations** into the repository, and then push it.

Now that GitLab is deployed with some example code, we are able to move on to the next step – building an actual pipeline!


## Deploying Tekton
Tekton is the pipeline system we're using for our platform. Originally part of the Knative project for building function-as-a-service on Kubernetes, Tekton has broken out into its own project. The biggest difference between Tekton and other pipeline technologies you may have run is that Tekton is Kubernetes-native. Everything from its execution system, definition, and webhooks for automation are able to run on just about any Kubernetes distribution you can find. For example, we'll be running it in KinD and Red Hat has moved to Tekton as the main pipeline technology used for OpenShift, starting with 4.1.

The process of deploying Tekton is pretty straightforward. Tekton is a series of operators that look for the creation of custom resources that define a build pipeline. The deployment itself only takes a couple of **kubectl** commands:

```bash
$ kubectl create ns tekton-pipelines
$ kubectl create -f chapter14/yaml/tekton-pipelines-policy.yaml
$ kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
$ kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
$ kubectl apply --filename https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
```

The first command deploys the base system needed to run Tekton pipelines. The second command deploys the components needed to build webhooks so that pipelines can be launched as soon as code is pushed. Once both commands are done and the Pods in the **tekton-pipelines** namespace are running, you're ready to start building a pipeline! We'll use our Python Hello World web service as an example.

### Building Hello World
Our Hello World application is really straightforward. It's a simple service that echoes back the obligatory "hello" and the host the service is running on just so we feel like our service is doing something interesting. Since the service is written in Python, we don't need to "build" a binary, but we do want to build a container. Once the container is built, we want to update the Git repository for our running namespace and let our GitOps system reconcile the change to redeploy our application. The steps for our build will be as follows:

1. Check out our latest code
1. Create a tag based on a timestamp
1. Build our image
1. Push to our registry
1. Patch a Deployment YAML file in the **operations** namespace

We'll build our pipeline one object at a time. The first set of tasks is to create an SSH key that Tekton will use to pull our source code:

1. Create an SSH key pair that we'll use for our pipeline to check out our code. When prompted for a passphrase, just hit Enter to skip adding a passphrase:
```bash
$ ssh-keygen -t rsa -m PEM -f ./gitlab-hello-python
```
2. Log in to GitLab and navigate to the *hello-python* project we created. Click on **Settings** | **Repository** | **Deploy Keys**, and click **Expand**. Use *tekton* as the title and paste the contents of the ***gitlab-hello-python.pub*** file you just created into the **Key** section. Keep **Write access allowed** ***unchecked*** and click **Add Key**.
3. Next, create the *python-hello-build* namespace and the following secret. Replace the *ssh-privatekey* attribute with the Base64-encoded content of the *gitlab-hello-python* file we created in ***step 1***. The annotation is what tells Tekton which server to use this key with. The server name is the *Service* in the GitLab namespace:
```yaml
// kubectl create namespace python-hello-build
// kubectl -n python-hello-build apply -f  git-pull.yaml
// kubectl -n python-hello-build get secret git-pull -o yaml
// 
apiVersion: v1
data:
  ssh-privatekey: ...
kind: Secret
metadata:
  annotations:
    tekton.dev/git-0: gitlab-gitlab-shell.gitlab.svc.cluster.local
  name: git-pull
  namespace: python-hello-build
type: kubernetes.io/ssh-auth
```
4. Create an SSH key pair that we'll use for our pipeline to push to the operations repository. When prompted for a passphrase, just hit Enter to skip adding a passphrase:
```bash
$ ssh-keygen -t rsa -m PEM -f ./gitlab-hello-python-operations
```
5. Log in to GitLab and navigate to the *hello-python-operations* project we created. Click on **Settings** | **Repository** | **Deploy Keys**, and click **Expand**. Use *tekton* as the title and paste the contents of the ***gitlab-hello-python-operations.pub*** file you just created into the **Key** section. Make sure **Write access allowed** is ***checked*** and click **Add Key**.
6. Next, create the following secret. Replace the *ssh-privatekey* attribute with the Base64-encoded content of the *gitlab-hello-python-operations* file we created in ***step 4***. The annotation is what tells Tekton which server to use this key with. The server name is the **Service** we created in ***step 6*** in the GitLab namespace:
```yaml
// kubectl create namespace python-hello-build
// kubectl -n python-hello-build apply -f  git-write.yaml
// kubectl -n python-hello-build get secret git-write -o yaml

apiVersion: v1
data:
  ssh-privatekey: ...
kind: Secret
metadata:
  name: git-write
  namespace: python-hello-build
type: kubernetes.io/ssh-auth
```
7. Create a service account for tasks to run, as with our secret:
```bash
$ kubectl create -f chapter14/example-apps/tekton/tekton-serviceaccount.yaml
```
8. We need a container that contains both git and kubectl. We'll build chapter14/example-apps/docker/PatchRepoDockerfile and push it to our internal registry. Make sure to replace 192-168-2-114 with the hostname for your server's IP address:
```bash
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
echo  https://docker.apps.$hostip.nip.io
cd  chapter14/example-apps/docker
docker build -f ./PatchRepoDockerfile -t docker.apps.$hostip.nip.io/gitcommit/gitcommit .
docker push docker.apps.$hostip.nip.io/gitcommit/gitcommit
```

The previous steps set up one key that Tekton will use to pull source code from our service's repository and another key that Tekton will use to update our deployment manifests with a new image tag. The operations repository will be watched by ArgoCD to make updates. Next, we will work on deploying a Tekton pipeline to build our application.

Tekton organizes a "pipeline" into several objects. The most basic unit is a **Task**, which launches a container to perform some measure of work. **Tasks** can be thought of like jobs; they run to completion but aren't long-running services. **Tasks** are collected into **PipeLines**, which define an environment and order of **Task** execution. Finally, a PipelineRun (or TaskRun) is used to initiate the execution of a **PipeLine** (or specific **Task**) and track its progress. There are more objects than is typical for most pipeline technologies, but this brings additional flexibility and scalability. By leveraging Kubernetes native APIs, it lets Kubernetes do the work of figuring out where to run, what security contexts to use, and so on. With a basic understanding of how Tekton pipelines are assembled, let's walk through a pipeline for building and deploying our example service.

Every **Task** object can take inputs and produce results that can be shared with other **Task** objects. Tekton can provide runs (whether it's **TaskRun** or **PipelineRun**) with a workspace where the state can be stored and retrieved from. Writing to workspaces allows us to share data between **Task** objects.

Before deploying our task and pipeline, let's step through the work done by each task. The first task generates an image tag and gets the SHA hash of the latest commit. The full source can be found in **chapter14/example-apps/tekton/tekton-task1.yaml**:

```yaml
- name: create-image-tag
  image: docker.apps.192-168-2-114.nip.io/gitcommit/gitcommit
  script: |-
    #!/usr/bin/env bash
    export IMAGE_TAG=$(date +"%m%d%Y%H%M%S")
    echo -n "$(resources.outputs.result-image.url):$IMAGE_TAG" > /tekton/results/image-url
    echo "'$(cat /tekton/results/image-url)'"
    cd $(resources.inputs.git-resource.path)
    RESULT_SHA="$(git rev-parse HEAD | tr -d '\n')"
    echo "Last commit : $RESULT_SHA"
    echo -n "$RESULT_SHA" > /tekton/results/commit-tag
```
Each step in a task is a container. In this case, we're using the container we built previously that has **kubectl** and **git** in it.

We don't need **kubectl** for this task, but we do need **git**. The first block of code generates an image name from the `result-image` URL and a timestamp. We could use the latest commit, but I like having a timestamp so that I can quickly tell how old a container is. We save the full image URL to ``/text/results/image-url``, which corresponds to a ``result`` we defined in our task called ``image-url``. A ``result`` on a **Task** tells Tekton that there should be data stored with this name in the workspace so it can be referenced by our pipeline or other tasks by referencing ``$(tasks.generate-image-tag.results.image-url)``, where generate-image-tag is the name of our Task, and ``image-url`` is the name of our ``result``.

Our next task, in ***chapter14/example-apps/tekton/tekton-task2.yaml***, generates a container from our application's source using Google's Kaniko project (https://github.com/GoogleContainerTools/kaniko). Kaniko lets you generate a container without needing access to a Docker daemon. This is great because you don't need a privileged container to build your image:

```yaml
steps:
- args:
  - --dockerfile=$(params.pathToDockerFile)
  - --destination=$(params.imageURL)
  - --context=$(params.pathToContext)
  - --verbosity=debug
  - --skip-tls-verify
  command:
  - /kaniko/executor
  env:
  - name: DOCKER_CONFIG
    value: /tekton/home/.docker/
  image: gcr.io/kaniko-project/executor:latest
  name: build-and-push
  resources: {}
```
> gcr.io/kaniko-project/executor in chapter14/example-apps/tekton/tekton-task2.yaml is v0.16.0  ! it maybe too old ? At 2021/1/28 , [the latest is v1.7.0](https://github.com/GoogleContainerTools/kaniko/releases) .


The Kaniko container is what's called a "distro-less" container. It's not built with an underlying shell, nor does it have many of the command-line tools you may be used to. It's just a single binary. This means that any variable manipulation, such as generating a tag for the image, needs to be done before this step. Notice that the image being created doesn't reference the result we created in the first task. It instead references a parameter called ``imageURL``. While we could have referenced the result directly, it would make it harder to test this task because it is now tightly bound to the first task. By using a parameter that is set by our pipeline, we can test this task on its own. Once run, this task will generate and push our container.

Our last task, in ***chapter14/example-apps/tekton/tekton-task-3.yaml***, does the work to trigger ArgoCD to roll out a new container:

```yaml
- image: docker.apps.192-168-2-114.nip.io/gitcommit/gitcommit
  name: patch-and-push
  resources: {}
  script: |-
    #!/bin/bash
    export GIT_URL="$(params.gitURL)"
    export GIT_HOST=$(sed 's/.*[@]\(.*\)[:].*/\1/' <<< "$GIT_URL")
    mkdir /usr/local/gituser/.ssh
    cp /pushsecret/ssh-privatekey /usr/local/gituser/.ssh/id_rsa
    chmod go-rwx /usr/local/gituser/.ssh/id_rsa      
    ssh-keyscan -H $GIT_HOST > /usr/local/gituser/.ssh/known_hosts
    cd $(workspaces.output.path)
    git clone $(params.gitURL) .
    kubectl patch --local -f src/deployments/hello-python.yaml -p '{"spec":{"template":{"spec":{"containers":[{"name":"python-hello","image":"$(params.imageURL)"}]}}}}' -o yaml > /tmp/hello-python.yaml
    cp /tmp/hello-python.yaml src/deployments/hello-python.yaml
    git add src/deployments/hello-python.yaml
    git commit -m 'commit $(params.sourceGitHash)'
    git push
```

The first block of code copies the SSH keys into our home directory, generates ``known_hosts``, and clones our repository into a workspace we defined in the **Task**. We don't rely on Tekton to pull the code from our **operations** repository because Tekton assumes we won't be pushing code, so it disconnects the source code from our repository. If we try to run a commit, it will fail. Since the step is a container, we don't want to try to write to it, so we create a workspace with ``emptyDir``, just like ``emptyDir`` in a ``Pod`` we might run. We could also define workspaces based on persistent volumes. This could come in handy to speed up builds where dependencies get downloaded.

We're copying the SSH key from ``/pushsecret``, which is defined as a volume on the task. Our container runs as user ***431***, but the SSH keys are mounted as root by Tekton. We don't want to run a privileged container just to copy the keys from a **Secret**, so instead, we mount it as if it were just a regular Pod.

Once we have our repository cloned, we patch our deployment with the latest image and finally, commit the change using the hash of the source commit in our application repository. Now we can track an image back to the commit that generated it! Just as with our second task, we don't reference the results of tasks directly to make it easier to test.

We pull these tasks together in a pipeline – specifically, ***chapter14/example-apps/tekton/tekton-pipeline***.yaml. This YAML file is several pages long, but the key piece defines our tasks and links them together. You should never hardcode values into your pipeline. Take a look at our third task's definition in the pipeline:

```yaml
- name: update-operations-git
    taskRef:
      name: patch-deployment
    params:
      - name: imageURL
        value: $(tasks.generate-image-tag.results.image-url)
      - name: gitURL
        value: $(params.gitPushUrl)
      - name: sourceGitHash
        value: $(tasks.generate-image-tag.results.commit-tag)
    workspaces:
    - name: output
      workspace: output
```

We reference parameters and task results, but nothing is hardcoded. This makes our *Pipeline* reusable. We also include the `runAfter` directive in our second and third tasks to make sure that our tasks are run in order. Otherwise, tasks will be run in parallel. Given each task has dependencies on the task before it, we don't want to run them at the same time. Next, let's deploy our pipeline and run it:

1. Add *chapter14/yaml/gitlab-shell-write.yaml* to your cluster; this is an endpoint so that Tekton can write to SSH using a separate key.
```bash
kubectl apply -f chapter14/yaml/gitlab-shell-write.yaml
kubectl -n gitlab get svc
```
2. Run *chapter14/shell/exempt-python-build.sh* to disable GateKeeper in our build namespace. This is needed because `Tekton's containers for checking out code run as root` and do not work when running with a random user ID.
```bash
./chapter14/shell/exempt-python-build.sh
```
3. Add the *chapter14/example-apps/tekton/tekton-source-git.yaml* file to your cluster; this tells Tekton where to pull your application code from.
```bash
kubectl apply -f chapter14/example-apps/tekton/tekton-source-git.yaml
kubectl -n python-hello-build  get pipelineresources
```
4. Edit *chapter14/example-apps/tekton/tekton-image-result.yaml*, replacing 192-168-2-114 with the hash representation of your server's IP address, and add it to your cluster.
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
sed "s/IPADDR/$hostip/g" < ./chapter14/example-apps/tekton/tekton-image-result.yaml  > /tmp/tekton-image-result.yaml
kubectl apply -f /tmp/tekton-image-result.yaml
```
or
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
sed "s/192-168-2-114/$hostip/g" < ./chapter14/example-apps/tekton/tekton-image-result.yaml  >  /tmp/tekton-image-result.yaml
kubectl apply -f /tmp/tekton-image-result.yaml
```
5. Edit *chapter14/example-apps/tekton/tekton-task1.yaml*, replacing the image host with the host for your Docker registry, and add the file to your cluster.
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
echo  https://docker.apps.$hostip.nip.io
sed "s/IPADDR/$hostip/g" < ./chapter14/example-apps/tekton/tekton-task1.yaml  > /tmp/tekton-task1.yaml
kubectl apply -f /tmp/tekton-task1.yaml
```
or
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
echo  https://docker.apps.$hostip.nip.io
sed "s/192-168-2-114/$hostip/g" < ./chapter14/example-apps/tekton/tekton-task1.yaml  >  /tmp/tekton-task1.yaml
kubectl apply -f /tmp/tekton-task1.yaml
```
6. Add *chapter14/example-apps/tekton/tekton-task2.yaml* to your cluster.
```bash
kubectl apply -f chapter14/example-apps/tekton/tekton-task2.yaml
kubectl -n python-hello-build  get tasks
```
7. Edit *chapter14/example-apps/tekton/tekton-task3.yaml*, replacing the image host with the host for your Docker registry, and add the file to your cluster.
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
echo  https://docker.apps.$hostip.nip.io
sed "s/IPADDR/$hostip/g" < ./chapter14/example-apps/tekton/tekton-task3.yaml  > /tmp/tekton-task3.yaml
kubectl apply -f /tmp/tekton-task3.yaml
kubectl -n python-hello-build  get tasks
```
or
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
echo  https://docker.apps.$hostip.nip.io
sed "s/192-168-2-140/$hostip/g" < ./chapter14/example-apps/tekton/tekton-task3.yaml  > /tmp/tekton-task3.yaml
kubectl apply -f /tmp/tekton-task3.yaml
kubectl -n python-hello-build  get tasks
```
8. Add *chapter14/example-apps/tekton/tekton-pipeline.yaml* to your cluster.
```bash
kubectl apply -f chapter14/example-apps/tekton/tekton-pipeline.yaml
kubectl -n python-hello-build  get pipelines
```
9. Add *chapter14/example-apps/tekton/tekton-pipeline-run.yaml* to your cluster.
```bash
kubectl apply -f chapter14/example-apps/tekton/tekton-pipeline-run.yaml
kubectl -n python-hello-build  get pipelines
```
You can check on the progress of your pipeline using **kubectl**, or you can use Tekton's CLI tool called ``tkn`` (https://github.com/tektoncd/cli). Running ``tkn pipelinerun describe build-hello-pipeline-run -n python-hello-build`` will list out the progress of your build. You can rerun the build by recreating your ``run`` object, but that's not very efficient. Besides, what we really want is for our pipeline to run on a commit!
```bash
kubectl delete -f chapter14/example-apps/tekton/tekton-pipeline-run.yaml
kubectl apply -f chapter14/example-apps/tekton/tekton-pipeline-run.yaml
kubectl -n python-hello-build  get pipelines
tkn pipelinerun describe build-hello-pipeline-run -n python-hello-build
```
### Building automatically
We don't want to manually run builds. We want builds to be automated. Tekton provides the trigger project to provide webhooks so that whenever GitLab receives a commit, it can tell Tekton to build a **PipelineRun** object for us. Setting up a trigger involves creating a Pod, with its own service account that can create **PipelineRun** objects, a Service for that Pod, and an **Ingress** object to host HTTPS access to the Pod. You also want to protect the webhook with a secret so that it isn't triggered inadvertently. Let's deploy these objects to our cluster:

1. Add *chapter14/example-apps/tekton/tekton-webhook-cr.yaml* to your cluster. This **ClusterRole** will be used by any namespace that wants to provision webhooks for builds.
```bash
kubectl apply -f ./chapter14/example-apps/tekton/tekton-webhook-cr.yaml
kubectl  get clusterroles  tekton-triggers-gitlab-minimal tekton-triggers-gitlab-cluster-minimal
```
1. Edit *chapter14/example-apps/tekton/tekton-webhook.yaml*. At the bottom of the file is an **Ingress** object. Change *192-168-18-24* to represent the IP of your cluster, with dashes instead of dots. Then, add the file to your cluster:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitlab-webhook
  namespace: python-hello-build
  annotations:
    cert-manager.io/cluster-issuer: ca-issuer
spec:
  rules:
  - host: "python-hello-application.build.IPADDR.nip.io"
    http:
      paths:
      - backend:
          service:
            name: el-gitlab-listener
            port: 
              number: 8080
        pathType: Prefix
        path: "/"
  tls:
  - hosts:
    - "python-hello-application.build.IPADDR.nip.io"
    secretName: ingresssecret
```
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
sed "s/IPADDR/$hostip/g" < ./chapter14/example-apps/tekton/tekton-webhook.yaml  > /tmp/tekton-webhook.yaml
kubectl apply -f /tmp/tekton-webhook.yaml
kubectl -n python-hello-build  get ing
```
or
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
sed "s/192-168-2-119/$hostip/g" < ./chapter14/example-apps/tekton/tekton-webhook.yaml  > /tmp/tekton-webhook.yaml
kubectl apply -f /tmp/tekton-webhook.yaml
kubectl -n python-hello-build  get ing
```

3. Log in to GitLab. Go to **Admin Area** | **Settings**  | **Network**. Click on **Expand** next to **Outbound Requests**. Check the **Allow requests to the local network from web hooks and services** option and click **Save changes**.
```
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g') 
echo https://gitlab.apps.$hostip.nip.io/
```
4. Go to the ``hello-python`` project we created and click on **Settings** | **Webhooks**. For the URL, use your *Ingress* host with HTTPS – for instance,*https://python-hello-application.build.192-168-18-24.nip.io/*. For **Secret Token**, use *notagoodsecret*, and for **Push events**, set the branch name to *main*. Finally, click on **Add webhook**.
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g') 
echo https://python-hello-application.build.$hostip.nip.io/
```

5. Once added, click on **Test**, choosing **Push Events**. If everything is configured correctly, a new *PipelineRun* object should have been created. You can run ``tkn pipelinerun list -n python-hello-build`` to see the list of runs; there should be a new one running. After a few minutes, you'll have a new container and a patched Deployment in the *python-hello-operations* project!

We covered quite a bit in this section to build our application and deploy it using GitOps. The good news is that everything is automated; a push will create a new instance of our application! The bad news is that we had to create over a dozen Kubernetes objects and manually make updates to our projects in GitLab. In the last section, we'll automate this process. First, let's deploy ArgoCD so that we can get our application running!

## Deploying ArgoCD
So far, we have a way to get into our cluster, a way to store code, and a system for building our code and generating images. The last component of our platform is our GitOps controller. This is the piece that lets us commit manifests to our Git repository and make changes to our cluster. ArgoCD is a tool from Intuit that provides a great UI and is driven by a combination of custom resources and Kubernetes-native ``ConfigMap`` and ``Secret`` objects. It has a CLI tool, and both the web and CLI tools are integrated with OpenID Connect, so it will be easy to add SSO with OpenUnison.

Let's deploy ArgoCD and use it to launch our ``hello-python`` web service:

1. Deploy using the standard YAML from https://argo-cd.readthedocs.io/en/stable/:
```bash
$ kubectl create namespace argocd
$ kubectl apply -f chapter14/argocd/argocd-policy.yaml
$ kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

2. Create the ``Ingress`` object for ArgoCD by running ``chapter14/deploy-argocd-ingress.sh``. This script sets the IP in the hostname correctly and adds the ingress objects to the cluster.
3. Get the root password by running ``kubectl get secret argocd-initial-admin-secret -n argocd -o json | jq -r '.data.password' | base64 -d``. Save this password.
4. We need to tell ArgoCD to run as a user and group 999 so our default mutation doesn't assign a user of 1000 and a group of 2000 to make sure SSH keys are read properly. Run the following patches:
```bash
$ kubectl patch deployment argocd-server -n argocd -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-server","securityContext":{"runAsUser":999,"runAsGroup":999}}]}}}}}'
$ kubectl patch deployment argocd-repo-server  -n argocd -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-repo-server","securityContext":{"runAsUser":999,"runAsGroup":999}}]}}}}}'
```
5. Edit the ``argocd-server`` **Deployment** in the ``argocd`` namespace. Add ``--insecure`` to the command:
```yaml
    spec:
      containers:
      - command:
        - argocd-server
        - --repo-server
        - argocd-repo-server:8081
        - --insecure
```
6. You can now log in to ArgoCD by going to the ``Ingress`` host you defined in ***step 2***. You will need to download the ArgoCD CLI utility as well from https://github.com/argoproj/argo-cd/releases/latest. Once downloaded, log in by running ``./argocd login grpc-argocd.apps.192-168-2-114.nip.io``, replacing ``192-168-2-114`` with the IP of your server, and with dashes instead of dots.
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
./argocd login grpc-argocd.apps.$hostip.nip.io
```
7. Create the python-hello namespace.
```bash
kubectl  create  namespace python-hello
```
8. Add *chapter14/yaml/python-hello-policy.yaml* to your cluster so we can run our service under strict security policies. We don't need a privileged container so why run with one?
```bash
kubectl apply -f chapter14/yaml/python-hello-policy.yaml
```

9. Before we can add our GitLab repository, we need to tell ArgoCD to trust our GitLab instance's SSH host. Since we will have ArgoCD talk directly to the GitLab shell service, we'll need to generate ``known_host`` for that Service. To make this easier, we included a script that will run ``known_host`` from outside the cluster but rewrite the content as if it were from inside the cluster. Run the **chapter14/shell/getSshKnownHosts.sh** script and pipe the output into the ``argocd`` command to import ``known_host``. Remember to change the hostname to reflect your own cluster's IP address:
```bash
$ ./chapter14/argocd/getSshKnownHosts.sh gitlab.apps.192-168-2-114.nip.io | argocd cert add-ssh --batch
Enter SSH known hosts entries, one per line. Press CTRL-D when finished.
Successfully created 3 SSH known host entries
```
10. Next, we need to generate an SSH key to access the ``python-hello-operations`` repository:
```bash
$ ssh-keygen -t rsa -m PEM -f ./argocd-python-hello
```
11. In GitLab, add the public key to the ``python-hello-operations`` repository by going to the project and clicking on **Settings** | **Repository**. Next to **Deploy Keys**, click **Expand**. For **Title**, use ``argocd``. Use the contents of ``argocd-python-hello.pub`` and click **Add key**. Then, add the key to ArgoCD using the CLI and replace the public GitLab host with the ``gitlab-gitlab-shell`` ``Service`` hostname:
```bash
$ argocd repo add git@gitlab-gitlab-shell.gitlab.svc.cluster.local:root/hello-python-operations.git --ssh-private-key-path ./argocd-python-hello
repository 'git@gitlab-gitlab-shell.gitlab.svc.cluster.local:root/hello-python-operations.git' added
```
12. Our last step is to create an ``Application`` object. You can create it through the web UI or the CLI. You can also create it by creating an ``Application`` object in the ``argocd`` namespace, which is what we'll do. Create the following object in your cluster (**chapter14/example-apps/argocd/argocd-python-hello.yaml**):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: python-hello
  namespace: argocd
spec:
  destination:
    namespace: python-hello
    server: https://kubernetes.default.svc
  project: default
  source:
    directory:
      jsonnet: {}
      recurse: true
    path: src
    repoURL: git@gitlab-gitlab-shell.gitlab.svc.cluster.local:root/hello-python-operations.git
    targetRevision: HEAD
  syncPolicy:
    automated: {}
```
This is about as basic a configuration as is possible. We're working off simple manifests. ArgoCD can work from JSONnet and Helm too. After this application is created, look at the Pods in the ``python-hello`` namespace. You should have one running! Making updates to your code will result in updates to the namespace.

We now have a code base that can be deployed automatically with a commit. We spent two dozen pages, ran dozens of commands, and created more than 20 objects to get there. Instead of manually creating these objects, it would be best to automate the process. Now that we have the objects that need to be created, we can automate the onboarding. In the next section, we will take the manual process of building the links between GitLab, Tekton, and ArgoCD to line up with our business processes.

## Automating project onboarding using OpenUnison
Earlier in this chapter, we deployed the OpenUnison NaaS portal. This portal lets users request new namespaces to be created and allows developers to request access to these namespaces via a self-service interface. The workflows built into this portal are very basic but create the namespace and appropriate RoleBinding objects. What we want to do is build a workflow that integrates our platform and creates all of the objects we created manually earlier in this chapter. The goal is that we're able to deploy a new application into our environment without having to run the kubectl command (or at least minimize its use).

This will require careful planning. Here's how our developer workflow will run:


Figure 14.6: Platform developer workflow

Let's quickly run through the workflow that we see in the preceding figure:

1. An application owner will request an application be created.
1. The infrastructure admin approves the creation.
1. At this point, OpenUnison will deploy the objects we created manually. We'll detail those objects shortly.
1. Once created, a developer is able to request access to the application.
1. The application owner(s) approves access to the application.
1. Once approved, the developer will fork the application source base and do their work. They can launch the application in their developer workspace. They can also fork the build project to create a pipeline and the development environment operations project to create manifests for the application.
1. Once the work is done and tested locally, the developer will push the code into their own fork and then request a merge request.
1. The application owner will approve the request and merge the code from GitLab.

Once the code is merged, ArgoCD will synchronize the build and operations projects. The webhook in the application project will kick off a Tekton pipeline that will build our container and update the development operations project with the tag for the latest container. ArgoCD will synchronize the updated manifest into our application's development namespace. Once testing is completed, the application owner submits a merge request from the development operations workspace to the production operations workspace, triggering ArgoCD to launch into production.

Nowhere in this flow is there a step called "operations staff uses kubectl to create a namespace." This is a simple flow and won't totally avoid your operations staff from using kubectl, but it should be a good starting point. All this automation requires an extensive set of objects to be created:


Figure 14.7: Application onboarding object map

The above diagram shows the objects that need to be created in our environment and the relationships between them. With so many moving parts, it's important to automate the process. Creating these objects manually is both time-consuming and error-prone. We'll work through that automation later in this chapter.

In GitLab, we create a project for our application code, operations, and build pipeline. We also fork the operations project as a development operations project. For each project, we generate deploy keys and register webhooks. We also create groups to match the roles we defined earlier in this chapter.

For Kubernetes, we create namespaces for the development and production environments. We also create a namespace for the Tekton pipeline. We add the keys as needed to Secrets. In the build namespace, we create all the scaffolding to support the webhook that will trigger automatic builds. That way, our developers only need to worry about creating their pipeline objects.

In our last application, ArgoCD, we will create an **AppProject** that hosts both our build and operations namespaces. We will also add the SSH keys we generated when creating our GitLab projects. Each project also gets an **Application** object in our **AppProject** that instructs ArgoCD how to synchronize from GitLab. Finally, we add RBAC rules to ArgoCD so that our developers can view their application synchronization status but owners and operations can make updates and changes.

### Designing a GitOps strategy
We have outlined the steps we want for our developer workflow and how we'll build those objects. Before we get into talking about implementation, let's work through how ArgoCD, OpenUnison, and Kubernetes will interact with each other.

So far, we've deployed everything manually in our cluster by running kubectl commands off of manifests that we put in this book's Git repo. That's not really the ideal way to do this. What if you needed to rebuild your cluster? Instead of manually recreating everything, wouldn't it be better to just let ArgoCD deploy everything from Git? We're not going to do that for this chapter, but it's something you should aim for as you design your own GitOps-based cluster. The more you can keep in Git, the better.

That said, how will OpenUnison communicate with the API server when it performs all this automation for us? The "easiest" way for OpenUnison is to just call the API server.


Figure 14.8: Writing objects directly to the API server

This will work. We'll get to our end goal of a developer workflow using GitOps, but what about our cluster management workflow? We want to get as many of the benefits from GitOps as cluster operators as our developers do! To that end, a better strategy would be to write our objects to a Git repository. That way, when OpenUnison creates these objects, they're tracked in Git, and if changes need to be made outside of OpenUnison, those changes are tracked too.


Figure 14.9: Writing objects to Git

When OpenUnison needs to create objects in Kubernetes, instead of writing them directly to the API server, it will write them into a management project in GitLab. ArgoCD will synchronize these manifests into the API server.

This is where we'll write any objects we don't want our users to have access to. This would include cluster-level objects, such as ***Namespaces***, but also namespace objects we don't want our users to have write access to, such as ***RoleBindings***. This way, we can separate operations object management from application object management.

Here's an important security question to answer: if ArgoCD is writing these objects for us, what's stopping a developer from checking in a ***RoleBinding*** or a ***ResourceQuota*** into their repo and letting ArgoCD synchronize it into the API server? At the time of publication, the only way to limit this is to tell ArgoCD which objects can be synchronized in the AppProject object. This isn't quite as useful as relying on RBAC, but should cover most use cases. For our deployments, we're going to allow just **Deployment**, **Service**, and **Ingress** objects. It wouldn't be unreasonable to add additional types for different use cases. Those updates can be made quite easily by updating an AppProject object in the management Git repo.

Finally, look at Figure 14.9 and you'll notice that we're still writing ***Secret*** objects to the API server. Don't write your secret information to Git. It doesn't matter if the data is encrypted or not; either way, you're asking for trouble. Git is specifically designed to make it easier to share code in a decentralized way, whereas your secret data should be tracked carefully by a centralized repository. These are two opposing requirements.

As an example of how easy it is to lose track of sensitive data, let's say you have a repo with ***Secrets*** in it on your workstation. A simple git archive HEAD will remove all Git metadata and give you clean files that can no longer be tracked. How easy is it to accidentally push a repo to a public repository by accident? It's just too easy to lose track of the code base.

Another example of why Git is a bad place to store secret information is that Git doesn't have any built-in authentication. When you use SSH or HTTPS when accessing a Git repo, either GitHub or GitLab is authenticating you, but Git itself has no form of built-in authentication. If you have followed the exercises in this chapter, go look at your Git commits. Do they say "root" or do they have your name? Git just takes the data from your Git configuration. There's nothing that ties that data to you. Is that an audit trail that will work for you as regards your organization's secret data? Probably not.

Some projects attempt to fix this by encrypting sensitive data in the repo. That way, even if the repo were leaked, you would still need the keys to decrypt the data. Where's the ***Secret*** for the encryption being stored? Is it in use by developers? Is there special tooling that's required? There are several places where it could go wrong. It's better to not use Git at all for sensitive data, such as ***Secrets***.

In a production environment, you want to externalize your ***Secrets*** though, just like your other manifests. There are multiple ***Secret*** management systems out there such as HashiCorp's Vault. These tools deserve their own chapter, or book, and are well outside the scope of this chapter, but you should certainly include them as part of your cluster management plan.

You don't need to build this out yourself! ***chapter14/naas-gitops*** is a Helm chart we'll deploy that has all this automation built-in. We also included ***chapter14/example-app/python-hello*** as our example application, ***chapter14/example-app/python-hello-operations*** for our manifests, and ***chapter14/example-app/python-hello-build*** as our pipeline. You'll need to tweak some of the objects in these three folders to match your environment, mostly updating the hostnames.

With our developer workflow designed and example projects ready to go, next, we'll update OpenUnison, GitLab, and ArgoCD to get all this automation to work!

### Integrating GitLab
We configured GitLab for SSO when we first deployed the Helm chart. The gitlab-oidc Secret we deployed has all the information GitLab needs to access SSO from OpenUnison. The naas-gitops Helm chart will configure SSO with GitLab and add a badge to the front page, just like for tokens and the dashboard. First, we need to update our OpenUnison Secret to complete the integration:

1. Log in to GitLab as root. Go to your user's profile area and click on Access Tokens. For Name, use openunison. Leave Expires blank and check the API scope. Click Create personal access token. Copy and paste the token into a notepad or some other place. Once you leave this screen, you can't retrieve this token again.  
2. Edit the orchestra-secrets-source Secret in the openunison namespace. Add two keys:
```yaml
apiVersion: v1
data:
  K8S_DB_SECRET: aW0gYSBzZWNyZXQ=
  OU_JDBC_PASSWORD: c3RhcnR0MTIz
  SMTP_PASSWORD: ""
  unisonKeystorePassword: aW0gYSBzZWNyZXQ=
  gitlab: c2VjcmV0
  GITLAB_TOKEN: S7CCuqHfpw3a6GmAqEYg
kind: Secret
```

Remember to Base64-encode the values. The **gitlab** key matches the secret in our ***oidc-provider*** Secret. ***GITLAB_TOKEN*** is going to be used by OpenUnison to interact with GitLab to provision the projects and groups we defined in our onboarding workflow. With GitLab configured, next is the TektonCD dashboard.

### Integrating the TektonCD dashboard
The TektonCD project has a great dashboard that makes it very easy to visualize pipelines and follow their execution. We didn't include it in the first edition of this book because there was no security integrated. Now, however, the TektonCD dashboard works with security and authentication the same way the Kubernetes dashboard does. Using a reverse proxy, we can provide either a user's ***id_token*** or impersonation headers. The naas-gitops chart has all of the OpenUnison-specific configuration, and there's nothing special we need to do to integrate the two. That said, let's deploy:
```bash
$ kubectl apply --filename https://storage.googleapis.com/tekton-releases/dashboard/latest/tekton-dashboard-release.yaml
```

This will deploy the TektonCD dashboard to the tekton-pipelines namespace, so we don't need to worry about adding node policies. We do need to remove several RBAC bindings though. We want the dashboard to run without any privileges to make sure that if someone did circumvent OpenUnison, they couldn't abuse it:

```bash
kubectl delete clusterrole tekton-dashboard-backend
kubectl delete clusterrole tekton-dashboard-dashboard
kubectl delete clusterrole tekton-dashboard-pipelines
kubectl delete clusterrole tekton-dashboard-tenant
kubectl delete clusterrole tekton-dashboard-triggers
kubectl delete clusterrolebinding tekton-dashboard-backend
kubectl delete rolebinding tekton-dashboard-pipelines -n tekton-pipelines
kubectl delete rolebinding tekton-dashboard-dashboard -n tekton-pipelines
kubectl delete rolebinding tekton-dashboard-triggers -n tekton-pipelines
kubectl delete clusterrolebinding tekton-dashboard-tenant
```

With the RBAC bindings deleted, next, we'll integrate ArgoCD.

### Integrating ArgoCD
ArgoCD has built-in support for OpenID Connect. It wasn't configured for us in the deployment, though:

1. Edit **argocd-cm** **ConfigMap** in the **argocd** namespace, adding the ***url*** and ***oidc.config keys***, as shown in the following code block. Make sure to update 192-168-2-140 to match your cluster's IP address. Mine is **192.168.2.114**, so I'll be using **192-168-2-114**:
```yaml
apiVersion: v1
data:
  url: https://argocd.apps.192-168-2-140.nip.io
  oidc.config: |-
    name: OpenUnison
    issuer: https://k8sou.apps.192-168-2-140.nip.io/auth/idp/k8sIdp
    clientID: argocd
    requestedScopes: ["openid", "profile", "email", "groups"]
```
> **⚠ ATTENTION:**  
> We don't specify a client secret with ArgoCD because it has both a CLI and a web component. Just like with the API server, it makes no sense to worry about a client secret that will need to reside on every single workstation that will be known to the user. It doesn't add any security in this case, so we will skip it.

2. While most of ArgoCD is controlled with Kubernetes custom resources, there are some ArgoCD-specific APIs. To work with these APIs, we need to create a service account. We'll need to create this account and generate a key for it:
```bash
$ kubectl patch configmap argocd-cm -n argocd -p '{"data":{"accounts.openunison":"apiKey","accounts.openunison.enabled":"true"}}'
$ argocd account generate-token --account openunison
```
3. Take the output of the **generate-token** command and add it as the **ARGOCD_TOKEN** key to **orchestra-secrets-source** **Secret** in the **openunison** namespace. Don't forget to Base64-encode it.
4. Finally, we want to create ArgoCD RBAC rules so that we can control who can access the web UI and the CLI. Edit argocd-rbac-cm ConfigMap and add the following keys. The first key will let our systems administrators and our API key do anything in ArgoCD. The second key maps all users that aren't mapped by policy.csv into a role into a non-existent role so that they won't have access to anything:
```yaml
data:  
  policy.csv: |-
    g, k8s-cluster-k8s-administrators,role:admin
    g, openunison,role:admin
  policy.default: role:none
```

With ArgoCD integrated, the final step involves deploying our custom chart!

### Updating OpenUnison
OpenUnison is already deployed. We need to deploy our Helm chart, which includes the automation that reflects our workflow:
```bash
$ cd chapter14/naas-gitops
$  kubectl delete configmap myvd-book -n openunison
configmap "myvd-book" deleted
$ helm install orchestra-naas . -n openunison -f /tmp/openunison-values.yaml
NAME: orchestra-naas
LAST DEPLOYED: Thu Oct  7 13:51:19 2021
NAMESPACE: openunison
STATUS: deployed
REVISION: 1
TEST SUITE: None
$ helm upgrade orchestra tremolo/orchestra -n openunison -f /tmp/openunison-values.yaml
```

Once the openunison-orchestra Pod is running again, log in to OpenUnison by going to https://k8sou.apps.192-168-18-24.nip.io/, replacing "192-168-18-24" with your own IP address, but with dashes instead of dots.

Use the username mmosley and the password start123. You'll notice that we have several new badges besides tokens and the dashboard.


Figure 14.10: OpenUnison NaaS portal

Since we're the first person to log in, we automatically have admin access to the portal and cluster management access for the cluster. The ArgoCD and GitLab badges will lead you to those apps. Click on the OpenID Connect login button and you'll SSO into both. The Tekton badge gives you SSO access to Tekton's dashboard. This will be helpful in debugging pipelines. The New Application badge is where the magic happens. That's where you can create a new application that will generate all the linkages you need between GitLab, ArgoCD, Kubernetes, and Tekton.

Before we create a new application, we need to create our cluster management project in GitLab and set up ArgoCD to synchronize it to our cluster. We could do this manually, but that would be painful, so we have a workflow that will do it for you:

1. Click on the **Operator's Console** badge
1. Check **Last Name** and type ***Mosley*** in the box
1. Click **Search**
1. Check the box next to **Matt** and then click on **Initialization** in the new tree that appears below
1. In the **Reason** field, type ***initialization***
1. Click **Submit Workflow**

Figure 14.11: Initializing the cluster repo

If you watch the OpenUnison logs, you'll see quite a bit of action. This workflow:

1. Creates the **cluster-operations** project in GitLab
1. Creates the **cluster-operations** Application in ArgoCD
1. Creates a webhook on the **cluster-operations** project in GitLab to automatically trigger a synchronization event in ArgoCD when a push is merged into the main branch

With our technology stack in place, now it's time to roll out our first application

## Deploying an application
So far, we've explored the theory of building pipelines and workflows, and we have also deployed a technology stack that implements that theory. The last step is to walk through the process of deploying an application in our cluster. There will be three actors in this flow.
| Username | Role                  | Notes                                                                                           |
|----------|-----------------------|-------------------------------------------------------------------------------------------------|
| **mmosley**  | System administrator  | Has overall control of the cluster. Responsible for approving new applications.                 |
| **jjackson** | Application owner     | Requests a new application. Is responsible for adding developers and merging pull requests.     |
| **app-dev**  | Application developer | Responsible for building code and manifests. Must work from forked versions of repos in GitLab. |
Table 14.1: Users of the system

Through the remainder of this section, we'll walk through creating a new application and deploying it using our automated framework.

### Creating the application in Kubernetes
As we move through this process, it will be helpful to have all three users able to log in. I generally use one browser with an incognito/private window for two users and a separate browser for the third. The password for all three users is start123.

Our first step is to log in to OpenUnison as jjackson. Upon logging in, you'll see that jjackson has a few less badges. That's because she's not an administrator. Once logged in, click on New Application. For Application Name, use python-hello, and for Reason use demo. Then, click Submit Registration.

Next, log in as mmosley. In the menu bar at the top of the screen, you'll see Open Approvals with a red 1 next to it. Click on Open Approvals.


Figure 14.12: Open Approvals

Next to the one open request, click Review. Scroll to the bottom and for Justification, put demo and click Approve Request. Then, click Confirm Approval. Now would be a good time to get a fresh cup of coffee. This will take a few minutes because multiple things are happening:

1. Projects in GitLab are being created to store your application code, pipelines, and manifests
1. Forks are being created for your manifests project
1. ArgoCD **AppProject** and **Applications** are being created
1. Namespaces are being created in your cluster for a development environment, build, and production
1. Tekton objects for building a pipeline are being created, with a webhook for triggers
1. Node security objects in dev and production namespaces are being created, so our applications will run without privilege
1. Webhooks are being created to link everything
1. Groups are being created in our database to manage access

We've built all the objects from the diagram in Figure 14.7 without editing a single **yaml** file or running kubectl. Once done, you can log in to GitLab as **mmosley** and see that the cluster-operations project now has all of our cluster-level objects. Just as we described earlier in the chapter, all of our objects, except **Secrets**, are stored in Git.

With our scaffolding in place, the next step is to get our developers access so that they can start building.

### Getting access to developers
Now that our development infrastructure is in place, the next step is to get our developer, app-dev, access.

Log in to OpenUnison with the username app-dev and the password start123. In the menu bar, click on Request Access.


Figure 14.13: Request Access

Next, click on the triangle next to Local Deployment and then click on Developers. Click on Add To Cart.


Figure 14.14: Adding developer access to the cart

Once you've added it to your cart, click on Check Out on the menu bar. On the right, where it says Supply Reason, type for work and click Submit Request.


Figure 14.15: Adding developer access to the cart

At this point, log out and log back in as jjackson. On the upper menu bar, there will be an Open Approvals option with a red 1 next to it. Just as when we were initializing the system, click on Open Approvals and approve the request of app-dev.

This workflow is different from the new application workflow we ran to create hello-python. Where that workflow created objects across four systems, this workflow just adds our user to a group in OpenUnison's database. Every component's access is driven by these groups, so now, instead of having to hunt down RoleBindings and group memberships across four platforms, we can audit access at one point.

Log out and log back in as app-dev. Click on the GitLab badge and sign in with OpenUnison. You'll see four projects.


Figure 14.16: Developer projects

These projects will drive your application's development and deployment. Here are the descriptions for each project:
| Name                               | Description                     |
|------------------------------------|---------------------------------|
| python-hello-application           | Your application's source code. |
| python-hello-build                 | Your TektonCD pipeline definition. This code is synced by ArgoCD into the python-hello-build Namespace in your cluster.   |
| dev/python-hello-operations        | The manifests for your application, such as Deployment definitions. This is a fork of the production operations project and is synced to the python-hello-prod Namespace by ArgoCD. |
| production/python-hello-operations | The manifests for your application in production. Changes should be pull requests from the dev operations project. ArgoCD synchronizes this project to the python-hello-prod Namespace.         |
Table 14.2: Project descriptions

Notice that on each project, our user is a developer. This means that we can fork the repository and submit pull requests (or merge requests as they are called in GitLab), but we can't edit the contents of the project ourselves. The next step is to start checking out projects and checking in code.

### Deploying dev manifests
The first thing we'll need to do is deploy our operational manifests into our "dev" environment. Inside GitLab, fork python-hello-dev/python-hello-operations into your personal namespace in GitLab. Make sure to fork from the python-hello-dev Namespace and NOT the python-hello-production Namespace.

Once forked, clone the project from your own namespace (App Dev). You'll need to attach an SSH key to your GitLab account. When you clone the project, you'll need to convert the URL provided by GitLab into an SSH URL. For instance, when I clone the repository, GitLab gives me git@gitlab.apps.192-168-18-24.nip.io:app-dev/python-hello-operations.git. However, when I clone the repository, I add ssh:// to the front and :2222 after the hostname so that Git can reach our GitLab SSH service:
```bash
$ git clone ssh://git@gitlab.apps.192-168-18-24.nip.io:2222/app-dev/python-hello-operations.git
Cloning into 'python-hello-operations'...
The authenticity of host '[gitlab.apps.192-168-18-24.nip.io]:2222 ([192.168.18.24]:2222)' can't be established.
ECDSA key fingerprint is SHA256:F8VKUrn0ugFoRrLSBc93JNdWsRv9Zwy9wFlL0ZPqSf4.
Are you sure you want to continue connecting (yes/no/[fingerprint])? Yes
Warning: Permanently added '[gitlab.apps.192-168-18-24.nip.io]:2222,[192.168.18.24]:2222' (ECDSA) to the list of known hosts.
remote: Enumerating objects: 3, done.
remote: Counting objects: 100% (3/3), done.
remote: Compressing objects: 100% (2/2), done.
remote: Total 3 (delta 0), reused 3 (delta 0), pack-reused 0
Receiving objects: 100% (3/3), done.
```
With our repository cloned, the next step is to copy in our manifests. We have a script that makes this easier by updating IP addresses and hostnames:
```bash
$ cd chapter14/sample-repo/python-hello-operations
$ ./deployToGit.sh /path/to/python-hello-operations python-hello
[main 3ce8b5c] initial commit
 2 files changed, 37 insertions(+), 2 deletions(-)
 create mode 100644 src/deployments/hello-python.yaml
Enumerating objects: 8, done.
Counting objects: 100% (8/8), done.
Delta compression using up to 8 threads
Compressing objects: 100% (4/4), done.
Writing objects: 100% (6/6), 874 bytes | 874.00 KiB/s, done.
Total 6 (delta 0), reused 0 (delta 0)
To ssh://gitlab.apps.192-168-18-24.nip.io:2222/app-dev/python-hello-operations.git 7f0fb7c..3ce8b5c  main -> main
```

Now, look in your forked project in GitLab and you will find a Deployment manifest that's ready to be synchronized into the development Namespace in our cluster. From inside your forked project, click on Merge Requests on the left-hand menu bar.

Figure 14.17: Merge requests menu

On the next screen, click on New merge request. This will bring up a screen to choose which branch you want to merge into dev. Choose main and then click Compare branches and continue.


Figure 14.18: Merge requests

You can update the information in the merge request for additional data. Click on Create merge request at the bottom of the page.

After a moment, the request will be ready to merge, but the merge button will be grayed out. That's because our developer, app-dev, does not have those rights in GitLab. The next step is to log in as jjackson to approve the request. This would be a good time to log in to OpenUnison as jjackson in another browser or private/incognito browser window.

Once logged into GitLab as jjackson, navigate to the python-hello-dev-python-hello-operations project and click on Merge requests on the left-hand side, just as you did with the app-dev user. This time, you'll see the open merge request. Click on the request and click the merge button. You've now successfully merged the changes from app-dev into your application's dev environment.

Within 3 minutes, ArgoCD will pick up these changes and sync them into your python-hello-dev Namespace. Log in to ArgoCD as app-dev, and you'll see that the python-hello-dev application has synchronized, but it's in a broken state. That's because Kubernetes is trying to pull an image that doesn't yet exist.

Now that we've got our development manifests ready to go, the next step is to deploy our Tekton pipeline.

### Deploying a Tekton pipeline
With our development manifests deployed, next we need to deploy a pipeline that will build a container and update our dev environment's manifests to point to that new container. We covered the manual steps on how to do this earlier in this chapter, so here we're going to focus on the process of deploying via GitOps. Log in to GitLab as app-dev and fork the python-hello-build project. There's only one of these! Just as before, clone the repository, remembering to use the SSH URL. Next, deploy our pipeline into the cloned repository:
```bash
$ cd chapter14/sample-repo/python-hello-build/
$ ./deployToGit.sh ~/demo-deploy/python-hello-build python-hello
 [main 0a6e833] initial commit
 6 files changed, 204 insertions(+), 2 deletions(-)
 create mode 100644 src/pipelineresources/tekton-image-result.yaml
 create mode 100644 src/pipelines/tekton-pipeline.yaml
 create mode 100644 src/tasks/tekton-task1.yaml
 create mode 100644 src/tasks/tekton-task2.yaml
 create mode 100644 src/tasks/tekton-task3.yaml
Enumerating objects: 18, done.
Counting objects: 100% (18/18), done.
Delta compression using up to 8 threads
Compressing objects: 100% (12/12), done.
Writing objects: 100% (13/13), 3.18 KiB | 3.18 MiB/s, done.
Total 13 (delta 1), reused 0 (delta 0)
To ssh://gitlab.apps.192-168-18-24.nip.io:2222/app-dev/python-hello-build.git
   7120c3f..0a6e833  main -> main
```

Earlier in this chapter, we manually configured the objects needed to set up a webhook so that when developers merge their changes, the pipeline will kick off automatically. OpenUnison deployed all that boilerplate code for us, so we don't need to set it up on our own. If you look in the python-hello-build Namespace in our cluster, it already has a webhook running.

Just as with our manifests, create a merge request as app-dev, and merge it as jjackson. Taking a look at ArgoCD, you'll see that the python-hello-build Application has our new objects in it. With our pipeline deployed, the next step is to run our pipeline by checking in some code.

### Running our pipeline
Everything is ready for us to build our code and deploy it into the development environment. First, as app-dev, fork the python-hello-application project and clone it. Once cloned, copy the application source into your repository:
```bash
$ cd chapter14/example-apps/python-hello
$ git archive --format=tar HEAD | tar xvf - -C /path/to/python-hello-application/
$ cd /path/to/python-hello-application/
$ git add *
$ git commit -m 'initial commit'
$ git push
```

Just as with the other repositories, open a merge request as app-dev, and merge as jjackson. Then, go to your Tekton dashboard and pick python-hello-build from the namespace picker in the upper right-hand corner.


Figure 14.19: Tekton Dashboard

If everything went smoothly, you should now have a pipeline running to build a container and update our development environment. If we look in our dev operations project, we'll see that there's a new commit by Tekton that merged in a change to the image of our dev environment to match the image we just built. The commit has the hash of the commit to our application project, so we can tie them together. Lastly, go to ArgoCD and look at the python-hello-dev application. It's now synchronizing (or will within 3 minutes) our update to dev and rolling out our new image.

Taking a look at the deployed manifest, we will see that it has the default user and group ID configuration, drops all capabilities, and runs without privilege. That's because we deployed GateKeeper and automated the policies that keep our nodes safe from our Pods.

We now have a running Pod in dev, so it's time to promote to production.

### Promoting to production
We've rolled out our application into development and done whatever testing we want to do. Now it's time to promote into production. Here is where the power of combining Git, Kubernetes, and automation really pays off. The move to production becomes the simplest part! Log in to GitLab as jjackson and navigate to the python-hello-dev/python-hello-operations project and create a merge request. This will merge our development environment into our production environment, which, in this case, means ArgoCD will update a Deployment to point to a new container. Once jjackson approves the merge, ArgoCD will get to work. Once synchronized, you're live!

We covered quite a bit of ground in this section. We deployed the application scaffolding into our environment, onboarded a developer, and rolled out our application with automated build pipelines. We used GitOps to manage everything and at no point did we use the kubectl command!

## Summary
Coming into this chapter, we hadn't spent much time on deploying applications. We wanted to close things out with a brief introduction to application deployment and automation. We learned about pipelines, how they are built, and how they run on a Kubernetes cluster. We explored the process of building a platform by deploying GitLab for source control, built out a Tekton pipeline to work in a GitOps model, and used ArgoCD to make the GitOps model a reality. Finally, we automated the entire process with OpenUnison.

Using the information in this chapter should give you some direction as to how you want to build your own platform. Using the practical examples in this chapter will help you map the requirements of your organization to the technology needed to automate your infrastructure. The platform we built in this chapter is far from complete. It should give you a map for planning your own platform that matches your needs.

Finally, thank you! Thank you for joining us on this adventure of building out a Kubernetes cluster. We hope that you have as much fun reading this book and building out the examples as we did creating it!

## Questions
1. True or false: A pipeline must be implemented to make Kubernetes work.   
  a. True  
  b. False  
2. What are the minimum steps of a pipeline?   
  a. Build, scan, test, and deploy  
  b. Build and deploy  
  c. Scan, test, deploy, and build  
  d. None of the above  
3. What is GitOps?   
  a. Running GitLab on Kubernetes  
  b. Using Git as an authoritative source for operations configuration   
  c. A silly marketing term  
  d. A product from a new start-up  
4. What is the standard for writing pipelines?   
  a. All pipelines should be written in YAML.  
  b. There are no standards; every project and vendor has its own implementation.   
  c. JSON combined with Go.   
  d. Rust.   
5. How do you deploy a new instance of a container in a GitOps model?   
  a. Use kubectl to update the Deployment or StatefulSet in the namespace.   
  b. Update the Deployment or StatefulSet manifest in Git, letting the GitOps controller update the objects in Kubernetes.   
  c. Submit a ticket that someone in operations needs to act on.  
  d. None of the above.  
6. True or false: All objects in GitOps need to be stored in your Git repository.  
  a. True  
  b. False  
7. True or false: You can automate processes any way you want.  
  a. True  
  b. False  