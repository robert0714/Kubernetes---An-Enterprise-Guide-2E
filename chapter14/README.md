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
sudo cp tls.crt /usr/share/ca-certificates/internal-ca.crt
sudo echo "internal-ca.crt" >> /etc/ca-certificates.conf
sudo update-ca-certificates
sudo reboot
```
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
Since my server is running on 192.168.2.119, my GitLab instance is running on https://gitlab.apps.192-168-2-119.nip.io/.

#### Creating example projects
To explore Tekton and ArgoCD, we will create two projects. One will be for storing a simple Python web service, while the other will store the manifests for running the service. Let's deploy these projects:

1. You'll need to upload an SSH public key. To interact with GitLab's Git repositories, we're going to be centralizing authentication via OpenID Connect. GitLab won't have a password for authentication. To upload your SSH public key, click on your user icon in the upper right-hand corner, and then click on the **SSH Keys** menu on the left-hand task bar. Here you can paste your SSH public key.
2. Create a project and call it **hello-python**. Keep the visibility private.
3. Clone the project using SSH. Because we're running on port **2222**, we need to change the URL provided by GitLab to be a proper SSH URL. For instance, my GitLab instance gives me the URL **git@gitlab.apps.192-168-2-114.nip.io:root/hello-python.git**. This needs to be changed to **ssh://git@gitlab.apps.192-168-2-114.nip.io:2222/root/hello-python.git**.
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
1. Patch a Deployment YAML file in the operations namespace

We'll build our pipeline one object at a time. The first set of tasks is to create an SSH key that Tekton will use to pull our source code:

1. Create an SSH key pair that we'll use for our pipeline to check out our code. When prompted for a passphrase, just hit Enter to skip adding a passphrase:
```bash
$ ssh-keygen -t rsa -m PEM -f ./gitlab-hello-python
```
2. Log in to GitLab and navigate to the hello-python project we created. Click on Settings | Repository | Deploy Keys, and click Expand. Use tekton as the title and paste the contents of the github-hello-python.pub file you just created into the Key section. Keep Write access allowed unchecked and click Add Key.
3. Next, create the build-python-hello namespace and the following secret. Replace the ssh-privatekey attribute with the Base64-encoded content of the gitlab-hello-python file we created in step 1. The annotation is what tells Tekton which server to use this key with. The server name is the Service in the GitLab namespace:
```yaml
apiVersion: v1
data:
  ssh-privatekey: ...
kind: Secret
metadata:
  annotations:
    tekton.dev/git-0: gitlab-gitlab-shell.gitlab.svc.cluster.local
  name: git-pull
  namespace: build-python-hello
type: kubernetes.io/ssh-auth
```
4. Create an SSH key pair that we'll use for our pipeline to push to the operations repository. When prompted for a passphrase, just hit Enter to skip adding a passphrase:
```bash
$ ssh-keygen -t rsa -m PEM -f ./gitlab-hello-python-operations
```
5. Log in to GitLab and navigate to the hello-python-operations project we created. Click on Settings | Repository | Deploy Keys, and click Expand. Use tekton as the title and paste the contents of the github-hello-python-operations.pub file you just created into the Key section. Make sure Write access allowed is checked and click Add Key.
6. Next, create the following secret. Replace the ssh-privatekey attribute with the Base64-encoded content of the gitlab-hello-python-operations file we created in step 4. The annotation is what tells Tekton which server to use this key with. The server name is the Service we created in step 6 in the GitLab namespace:
```yaml
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
$ docker build -f ./PatchRepoDockerfile -t \
  docker.apps.192-168-2-114.nip.io/gitcommit/gitcommit .
$ docker push \
  docker.apps.192-168-2-114.nip.io/gitcommit/gitcommit
```

The previous steps set up one key that Tekton will use to pull source code from our service's repository and another key that Tekton will use to update our deployment manifests with a new image tag. The operations repository will be watched by ArgoCD to make updates. Next, we will work on deploying a Tekton pipeline to build our application.

Tekton organizes a "pipeline" into several objects. The most basic unit is a **Task**, which launches a container to perform some measure of work. **Tasks** can be thought of like jobs; they run to completion but aren't long-running services. **Tasks** are collected into **PipeLines**, which define an environment and order of **Task** execution. Finally, a PipelineRun (or TaskRun) is used to initiate the execution of a **PipeLine** (or specific **Task**) and track its progress. There are more objects than is typical for most pipeline technologies, but this brings additional flexibility and scalability. By leveraging Kubernetes native APIs, it lets Kubernetes do the work of figuring out where to run, what security contexts to use, and so on. With a basic understanding of how Tekton pipelines are assembled, let's walk through a pipeline for building and deploying our example service.

Every **Task** object can take inputs and produce results that can be shared with other **Task** objects. Tekton can provide runs (whether it's **TaskRun** or **PipelineRun**) with a workspace where the state can be stored and retrieved from. Writing to workspaces allows us to share data between **Task** objects.

Before deploying our task and pipeline, let's step through the work done by each task. The first task generates an image tag and gets the SHA hash of the latest commit. The full source can be found in **chapter14/example-apps/tekton/tekton-task1.yaml**: