# Chapter 12 An Introduction to Istio
## Installing Istio
### Downloading Istio
The first thing that we need is to define the version of Istio we want to deploy. We can do this by setting an environment variable, and in our example, we want to deploy Istio 1.10.6:

```bash 
export ISTIO_VERSION=1.10.6
```

Next, we will download the Istio installer using CURL:

```bash 
curl -L https://istio.io/downloadIstio | sh -
```

This will download the installation script and execute it using the ISTIO_VERSION that we defined before executing the curl command. After executing you will have an istio-1.10.6 directory in your current working directory.

Finally, since we will be using executables from the istio-1.10.6 directory, you should add it to your path statement. To make this easier, you should be in the chapter12 directory from the book repository before setting the path variable.

```bash 
export PATH="$PATH:$PWD/istio-1.10.6/bin"
```
### Installing Istio using a Profile

To make deploying Istio easier, the team has included a number of pre-defined profiles. Each profile defines which components are deployed and the default configuration. There are six profiles included, but only four profiles are used for most deployments.

| Profile | Installed Components                                  |
|---------|-------------------------------------------------------|
| Default | istio-ingressgateway and istiod                       |
| Demo    | istio-egressgateway, istio-ingressgateway, and istiod |
| Minimal | istiod                                                |
| Preview | istio-ingressgateway and istiod                       |

If none of the included profiles fit your deployment requirements, you can create a customized deployment. This is beyond the scope of this chapter since we will be using the included demo profile – however, you can read more about customizing the configuration on Istio's site, https://istio.io/latest/docs/setup/additional-setup/customize-installation/.

To deploy Istio using the demo profile using istioctl, we simply need to execute a single command:

```bash 
istioctl manifest install --set profile=demo
```
The istioctl executable can be used to verify the installation. To verify the installation, you require a manifest and since we used istioctl to deploy Istio directly, we do not have a manifest, so we need to create one to check our installation.

```bash 
istioctl manifest generate --set profile=demo > istio-kind.yaml
```

Then run the istioctl verify-install command.

```bash 
istioctl verify-install -f istio-kind.yaml
```

With Istio deployed, our next step is to expose it to our network so we can access the applications we'll build. Since we're running on KinD this can be tricky. Docker is forwarding all traffic from port ***80*** (HTTP) and ***443*** (HTTPS) on our KinD server to the worker node. The worker node is in turn running the NGINX Ingress controller on ports ***443*** and ***80*** to receive that traffic. In a real-world scenario, we'd use an external load balancer, like MetalLB, to expose the individual services via a ***LoadBalancer***. For our labs though, we're going to instead focus on simplicity. We created a script in the ***chapter12*** directory called ***expose_istio.sh*** that will do two things. First, it will delete the ***ingress-nginx*** namespace, removing NGINX and freeing up ports 80 and 443 on the Docker host. Second, it will patch the ***istio-ingressgateway*** Deployment in the ***istio-system*** namespace so that it runs on ports ***80*** and ***443*** on the worker node.

