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

1. You'll need to upload an SSH public key. To interact with GitLab's Git repositories, we're going to be centralizing authentication via OpenID Connect. GitLab won't have a password for authentication. To upload your SSH public key, click on your user icon in the upper right-hand corner, and then click on the **SSH Keys** menu on the left-hand task bar. Here you can paste your SSH public key.[referecnce](https://docs.gitlab.com/ee/ssh/)
```bash
ssh-keygen -t rsa -b 2048
```
To set ~/.ssh/config
```config
## ~/.ssh/config
Host gitlab.apps.192-168-18-24.nip.io
  PreferredAuthentications publickey
  IdentityFile ~/.ssh/id_rsa
```
Verify that your SSH key was added correctly.
```bash
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
2. Log in to GitLab and navigate to the *hello-python* project we created. Click on **Settings** | **Repository** | **Deploy Keys**, and click **Expand**. Use *tekton* as the title and paste the contents of the *github-hello-python.pub* file you just created into the **Key** section. Keep **Write access allowed** unchecked and click **Add Key**.
3. Next, create the *build-python-hello* namespace and the following secret. Replace the *ssh-privatekey* attribute with the Base64-encoded content of the *gitlab-hello-python* file we created in step 1. The annotation is what tells Tekton which server to use this key with. The server name is the *Service* in the GitLab namespace:
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
Each step in a task is a container. In this case, we're using the container we built previously that has kubectl and git in it.

We don't need kubectl for this task, but we do need git. The first block of code generates an image name from the result-image URL and a timestamp. We could use the latest commit, but I like having a timestamp so that I can quickly tell how old a container is. We save the full image URL to /text/results/image-url, which corresponds to a result we defined in our task called image-url. A result on a Task tells Tekton that there should be data stored with this name in the workspace so it can be referenced by our pipeline or other tasks by referencing $(tasks.generate-image-tag.results.image-url), where generate-image-tag is the name of our Task, and image-url is the name of our result.

Our next task, in chapter14/example-apps/tekton/tekton-task2.yaml, generates a container from our application's source using Google's Kaniko project (https://github.com/GoogleContainerTools/kaniko). Kaniko lets you generate a container without needing access to a Docker daemon. This is great because you don't need a privileged container to build your image:

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

The Kaniko container is what's called a "distro-less" container. It's not built with an underlying shell, nor does it have many of the command-line tools you may be used to. It's just a single binary. This means that any variable manipulation, such as generating a tag for the image, needs to be done before this step. Notice that the image being created doesn't reference the result we created in the first task. It instead references a parameter called imageURL. While we could have referenced the result directly, it would make it harder to test this task because it is now tightly bound to the first task. By using a parameter that is set by our pipeline, we can test this task on its own. Once run, this task will generate and push our container.

Our last task, in chapter14/example-apps/tekton/tekton-task-3.yaml, does the work to trigger ArgoCD to roll out a new container:

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

The first block of code copies the SSH keys into our home directory, generates known_hosts, and clones our repository into a workspace we defined in the Task. We don't rely on Tekton to pull the code from our operations repository because Tekton assumes we won't be pushing code, so it disconnects the source code from our repository. If we try to run a commit, it will fail. Since the step is a container, we don't want to try to write to it, so we create a workspace with emptyDir, just like emptyDir in a Pod we might run. We could also define workspaces based on persistent volumes. This could come in handy to speed up builds where dependencies get downloaded.

We're copying the SSH key from /pushsecret, which is defined as a volume on the task. Our container runs as user 431, but the SSH keys are mounted as root by Tekton. We don't want to run a privileged container just to copy the keys from a Secret, so instead, we mount it as if it were just a regular Pod.

Once we have our repository cloned, we patch our deployment with the latest image and finally, commit the change using the hash of the source commit in our application repository. Now we can track an image back to the commit that generated it! Just as with our second task, we don't reference the results of tasks directly to make it easier to test.

We pull these tasks together in a pipeline – specifically, chapter14/example-apps/tekton/tekton-pipeline.yaml. This YAML file is several pages long, but the key piece defines our tasks and links them together. You should never hardcode values into your pipeline. Take a look at our third task's definition in the pipeline:

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

We reference parameters and task results, but nothing is hardcoded. This makes our Pipeline reusable. We also include the runAfter directive in our second and third tasks to make sure that our tasks are run in order. Otherwise, tasks will be run in parallel. Given each task has dependencies on the task before it, we don't want to run them at the same time. Next, let's deploy our pipeline and run it:

1. Add chapter14/yaml/gitlab-shell-write.yaml to your cluster; this is an endpoint so that Tekton can write to SSH using a separate key.
1. Run chapter14/shell/exempt-python-build.sh to disable GateKeeper in our build namespace. This is needed because Tekton's containers for checking out code run as root and do not work when running with a random user ID.
1. Add the chapter14/example-apps/tekton/tekton-source-git.yaml file to your cluster; this tells Tekton where to pull your application code from.
1. Edit chapter14/example-apps/tekton/tekton-image-result.yaml, replacing 192-168-2-114 with the hash representation of your server's IP address, and add it to your cluster.
1. Edit chapter14/example-apps/tekton/tekton-task1.yaml, replacing the image host with the host for your Docker registry, and add the file to your cluster.
1. Add chapter14/example-apps/tekton/tekton-task2.yaml to your cluster.
1. Edit chapter14/example-apps/tekton/tekton-task3.yaml, replacing the image host with the host for your Docker registry, and add the file to your cluster.
1. Add chapter14/example-apps/tekton/tekton-pipeline.yaml to your cluster.
1. Add chapter14/example-apps/tekton/tekton-pipeline-run.yaml to your cluster.

You can check on the progress of your pipeline using kubectl, or you can use Tekton's CLI tool called tkn (https://github.com/tektoncd/cli). Running tkn pipelinerun describe build-hello-pipeline-run -n python-hello-build will list out the progress of your build. You can rerun the build by recreating your run object, but that's not very efficient. Besides, what we really want is for our pipeline to run on a commit!

### Building automatically
We don't want to manually run builds. We want builds to be automated. Tekton provides the trigger project to provide webhooks so that whenever GitLab receives a commit, it can tell Tekton to build a PipelineRun object for us. Setting up a trigger involves creating a Pod, with its own service account that can create PipelineRun objects, a Service for that Pod, and an Ingress object to host HTTPS access to the Pod. You also want to protect the webhook with a secret so that it isn't triggered inadvertently. Let's deploy these objects to our cluster:

1. Add chapter14/example-apps/tekton/tekton-webhook-cr.yaml to your cluster. This ClusterRole will be used by any namespace that wants to provision webhooks for builds.
1. Edit chapter14/example-apps/tekton/tekton-webhook.yaml. At the bottom of the file is an Ingress object. Change 192-168-2-119 to represent the IP of your cluster, with dashes instead of dots. Then, add the file to your cluster:
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
  - host: "python-hello-application.build.192-168-2-119.nip.io"
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
    - "python-hello-application.build.192-168-2-114.nip.io"
    secretName: ingresssecret
```
3. Log in to GitLab. Go to Admin Area | Network. Click on Expand next to Outbound Requests. Check the Allow requests to the local network from web hooks and services option and click Save changes.
4. Go to the hello-python project we created and click on Settings | Webhooks. For the URL, use your Ingress host with HTTPS – for instance, https://python-hello-application.build.192-168-2-119.nip.io/. For Secret Token, use notagoodsecret, and for Push events, set the branch name to main. Finally, click on Add webhook.
5. Once added, click on Test, choosing Push Events. If everything is configured correctly, a new PipelineRun object should have been created. You can run tkn pipelinerun list -n python-hello-build to see the list of runs; there should be a new one running. After a few minutes, you'll have a new container and a patched Deployment in the python-hello-operations project!

We covered quite a bit in this section to build our application and deploy it using GitOps. The good news is that everything is automated; a push will create a new instance of our application! The bad news is that we had to create over a dozen Kubernetes objects and manually make updates to our projects in GitLab. In the last section, we'll automate this process. First, let's deploy ArgoCD so that we can get our application running!

## Deploying ArgoCD
So far, we have a way to get into our cluster, a way to store code, and a system for building our code and generating images. The last component of our platform is our GitOps controller. This is the piece that lets us commit manifests to our Git repository and make changes to our cluster. ArgoCD is a tool from Intuit that provides a great UI and is driven by a combination of custom resources and Kubernetes-native ConfigMap and Secret objects. It has a CLI tool, and both the web and CLI tools are integrated with OpenID Connect, so it will be easy to add SSO with OpenUnison.

Let's deploy ArgoCD and use it to launch our hello-python web service:

1. Deploy using the standard YAML from https://argo-cd.readthedocs.io/en/stable/:
```bash
$ kubectl create namespace argocd
$ kubectl apply -f chapter14/argocd/argocd-policy.yaml
$ kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

2. Create the Ingress object for ArgoCD by running chapter14/deploy-argocd-ingress.sh. This script sets the IP in the hostname correctly and adds the ingress objects to the cluster.
3. Get the root password by running kubectl get secret argocd-initial-admin-secret -n argocd -o json | jq -r '.data.password' | base64 -d. Save this password.
4. We need to tell ArgoCD to run as a user and group 999 so our default mutation doesn't assign a user of 1000 and a group of 2000 to make sure SSH keys are read properly. Run the following patches:
```bash
$ kubectl patch deployment argocd-server -n argocd -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-server","securityContext":{"runAsUser":999,"runAsGroup":999}}]}}}}}'
$ kubectl patch deployment argocd-repo-server  -n argocd -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-repo-server","securityContext":{"runAsUser":999,"runAsGroup":999}}]}}}}}'
```
5. Edit the argocd-server Deployment in the argocd namespace. Add --insecure to the command:
```yaml
    spec:
      containers:
      - command:
        - argocd-server
        - --repo-server
        - argocd-repo-server:8081
        - --insecure
```
6. You can now log in to ArgoCD by going to the Ingress host you defined in step 2. You will need to download the ArgoCD CLI utility as well from https://github.com/argoproj/argo-cd/releases/latest. Once downloaded, log in by running ./argocd login grpc-argocd.apps.192-168-2-114.nip.io, replacing 192-168-2-114 with the IP of your server, and with dashes instead of dots.
7. Create the python-hello namespace.
8. Add chapter14/yaml/python-hello-policy.yaml to your cluster so we can run our service under strict security policies. We don't need a privileged container so why run with one?
9. Before we can add our GitLab repository, we need to tell ArgoCD to trust our GitLab instance's SSH host. Since we will have ArgoCD talk directly to the GitLab shell service, we'll need to generate known_host for that Service. To make this easier, we included a script that will run known_host from outside the cluster but rewrite the content as if it were from inside the cluster. Run the chapter14/shell/getSshKnownHosts.sh script and pipe the output into the argocd command to import known_host. Remember to change the hostname to reflect your own cluster's IP address:
```bash
$ ./chapter14/argocd/getSshKnownHosts.sh gitlab.apps.192-168-2-114.nip.io | argocd cert add-ssh --batch
Enter SSH known hosts entries, one per line. Press CTRL-D when finished.
Successfully created 3 SSH known host entries
```
10. Next, we need to generate an SSH key to access the python-hello-operations repository:
```bash
$ ssh-keygen -t rsa -m PEM -f ./argocd-python-hello
```
11. In GitLab, add the public key to the python-hello-operations repository by going to the project and clicking on Settings | Repository. Next to Deploy Keys, click Expand. For Title, use argocd. Use the contents of argocd-python-hello.pub and click Add key. Then, add the key to ArgoCD using the CLI and replace the public GitLab host with the gitlab-gitlab-shell Service hostname:
```bash
$ argocd repo add git@gitlab-gitlab-shell.gitlab.svc.cluster.local:root/hello-python-operations.git --ssh-private-key-path ./argocd-python-hello
repository 'git@gitlab-gitlab-shell.gitlab.svc.cluster.local:root/hello-python-operations.git' added
```
12. Our last step is to create an Application object. You can create it through the web UI or the CLI. You can also create it by creating an Application object in the argocd namespace, which is what we'll do. Create the following object in your cluster (chapter14/example-apps/argocd/argocd-python-hello.yaml):
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
This is about as basic a configuration as is possible. We're working off simple manifests. ArgoCD can work from JSONnet and Helm too. After this application is created, look at the Pods in the python-hello namespace. You should have one running! Making updates to your code will result in updates to the namespace.

We now have a code base that can be deployed automatically with a commit. We spent two dozen pages, ran dozens of commands, and created more than 20 objects to get there. Instead of manually creating these objects, it would be best to automate the process. Now that we have the objects that need to be created, we can automate the onboarding. In the next section, we will take the manual process of building the links between GitLab, Tekton, and ArgoCD to line up with our business processes.