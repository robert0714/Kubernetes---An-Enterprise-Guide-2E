# Chapter 13 Building and Deploying Applications on Istio
## Technical requirements

```bash
./chapter2/create-cluster.sh
export ISTIO_VERSION=1.10.6
curl -L https://istio.io/downloadIstio | sh -
export PATH="$PATH:$PWD/istio-1.10.6/bin"
istioctl manifest install --set profile=demo
istioctl manifest generate --set profile=demo > istio-kind.yaml
istioctl verify-install -f istio-kind.yaml
helm install --namespace istio-system --set auth.strategy="anonymous" --repo https://kiali.org/helm-charts kiali-server kiali-server 
./chpater12/expose_istio.sh
```

## Deploying a monolith
Assuming you started with a fresh cluster, we're going to deploy OpenUnison the same way we did in Chapter 5, Integration Authentication into Your Cluster, but this time we have a script that does everything for you. Go into the chapter13 directory and run deploy_openunison_istio.sh:
```bash
cd chapter13
./deploy_openunison_istio.sh
```
### Exposing our monolith outside our cluster
### Configuring sticky sessions
### Integrating Kiali and OpenUnison
## Building a microservice
Having identified all the things our service will do, the next step is to identify which part of our infrastructure will be responsible for each decision and action. For our service:
| Action                                          | Component   | Description                                                                                  |
|-------------------------------------------------|-------------|----------------------------------------------------------------------------------------------|
| User Authentication                             | OpenUnison  | Our OpenUnison instance will authenticate users to our "Active Directory"                    |
| Service Routing                                 | Istio       | How we will expose our service to the world                                                  |
| Service Authentication                          | Istio       | The RequestAuthentication object will describe how to validate the user for our service      |
| Service Coarse Grained Authorization            | Istio       | AuthorizationPolicy will make sure users are members of a specific group to call our service |
| Fine-Grained Authorization, or Entitlements     | Service     | Our service will determine which payees you're able to write checks for                      |
| Writing a check                                 | Service     | The point of writing this service!                                                           |
| Log who wrote the check and to whom it was sent | Service     | Write this data to standard-out                                                              |
| Log aggregation                                 | Kubernetes  | Maybe Elastic?                                                                               |

### Deploying Hello World
### Integrating authentication into our service
Even before we configure our objects, we need to get a JWT from somewhere. We're going to use OpenUnison. To work with our API, let's deploy the pipeline token generation chart we deployed in Chapter 5, Integrating Authentication into Your Cluster. Go to the chapter5 directory and run the Helm Chart:
```bash
helm install orchestra-token-api token-login -n openunison -f /tmp/openunison-values.yaml
```
This will give us a way to easily generate a JWT from our internal "Active Directory". Next, we'll deploy the actual policy objects. Go into the chapter13/authentication directory and run ***deploy-auth.sh***. It will look like:
```bash
./deploy-auth.sh
```
### Authorizing access to our service
It turns out we have everything we need. Earlier we looked at our mmosley user's JWT, which had multiple claims. One such claim was the groups claim. We used this claim in Chapter 5, Integrating Authentication into Your Cluster and Chapter 6, RBAC Policies and Auditing, to manage access to our cluster. In a similar fashion we'll manage who can access our service based on our membership of a particular group. First, we'll delete our existing policy:
```bash
kubectl delete authorizationpolicy simple-hellow-world -n istio-hello-world
```

This policy tells Istio that only users with a claim called groups that has the value cn=group2,ou=Groups,DC=domain,DC=com are able to access this service. With this policy deployed you'll notice you can still access the service as mmosley, and trying to access the service anonymously still fails. Next, try accessing the service as jjackson, with the same password:
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
curl -H "Authorization: Bearer $(curl --insecure -u 'jjackson:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')" 
```
### Telling your service who's using it
We can view this header with a service we built, called /headers. This service will just give us back all the headers that are passed to our service. Let's take a look:
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
curl  -H "Authorization: Bearer $(curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')" http://service.192-168-2-119.nip.io/headers 2>/dev/null | jq -r '.headers' 
```

In addition to not requiring that our code knows how to verify the JWT, this also makes it easier for us to develop our code in isolation from Istio. Open a shell into your run-service pod and try accessing this service directly with any user:
```bash
kubectl exec -ti run-service-785775bf98-g86gl -n istio-hello-world –- bash
# export USERINFO=$(echo -n '{"sub":"marc","groups":["group1","group2"]}' | base64 -w 0)
# curl -H "User-Info: $USERINFO" http://localhost:8080/who-am-i
```


Let's try this directly from a namespace that doesn't have the Istio sidecar:
```bash
kubectl run -i --tty curl --image=alpine --rm=true -- sh
/ # apk update add curl
/ # curl -H "User-Info $(echo -n '{"sub":"marc","groups":["group1","group2"]}' | base64 -w 0)" http://run-service.istio-hello-world.svc/who-am-i
```

Our RequestAuthentication and AuthorizationPolicy stop the request. While we're not running the sidecar, our service is, and redirects all traffic to Istio where our policies will be enforced. What about if we try to inject our own User-Info header from a valid request?
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
export USERINFO=$(echo -n '{"sub":"marc","groups":["group1","group2"]}' | base64 -w 0)
curl  -H "Authorization: Bearer $(curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')" -H "User-Info: $USERINFO" http://service.$hostip.nip.io/who-am-i
{"name": "mmosley", "groups": ["cn=group2,ou=Groups,DC=domain,DC=com", "cn=k8s-cluster-admins,ou=Groups,DC=domain,DC=com"]}
```

### Authorizing user entitlements
#### Authorizing in service
#### Using OPA with Istio

### Calling other services
#### Using OAuth2 Token Exchange
#### Passing tokens between services
#### Using simple impersonation


## Do I need an API gateway?
If you're using Istio, do you still need an API gateway? In the past, Istio has been primarily concerned with routing traffic for services. It got traffic into the cluster and figured out where to route it to. API gateways have more typically been focused on application-level functionality such as authentication, authorization, input validation, and logging.

For example, earlier in this chapter we identified schema input validation as a process that needs to be repeated for each call and shouldn't need to be done manually. This is important to protect against attacks that can leverage unexpected input and also makes for a better developer experience to provide feedback to developers sooner in the integration process. This is a common function for API gateways, but is not available in Istio.

Another example of a function that is not built into Istio, but is common for API gateways, is logging authentication and authorization decisions and information. Throughout this chapter, we have leveraged Istio's built-in authentication and authorization to validate service access, but Istio makes no record of that decision other than that a decision was made. It doesn't record who accessed a particular URL, only where it was accessed from. Logging who accessed a service, from an identity standpoint, is left to each individual service. This is a common function for API gateways.

Finally, API gateways are able to handle more complex transformations. Gateways will typically provide functionality for mapping inputs, outputs, or even integrating with legacy systems.

These functions could all be integrated into Istio, either directly or via Envoy filters. We saw an example of this when we looked at using OPA to make more complex authorization decisions than what the AuthorizationPolicy object provides. Over the last few releases, though, Istio has moved more into the realm of traditional API gateways, and API gateways have begun taking on more service mesh capabilities. I suspect there will be considerable overlap between these systems in the coming years, but as of today, Istio isn't yet capable of fulfilling all the functions of an API gateway.

We've had quite the journey building out the services for our Istio service mesh. You should now have the tools you need to begin building services in your own cluster.

## Summary
In this chapter, we learned how both monoliths and microservices run in Istio. We explored why and when to use each approach. We deployed a monolith, taking care to ensure our monolith's session management worked. We then moved into deploying microservices, authenticating requests, authorizing requests, and finally how services can securely communicate. To wrap things up, we discussed whether an API gateway is still necessary when using Istio.

Istio can be complex, but when used properly it can provide considerable power. What we didn't cover in this chapter is how to build containers and manage the deployment of our services. We're going to tackle that next in Chapter 14, Provisioning a Platform.

## Questions
1. True or false: Istio is an API Gateway.  
    a. True   
    b. False  
    Answer: b. False – Istio is a service mesh, and while it has many functions of a gateway, it doesn't have all of them (such as schema checking).

2. Should I always build applications as microservices?  
    a. Obviously, this is the way.  
    b. Only if a microservices architecture aligns with your organization's structure and needs.  
    c. No, microservices are more trouble than they're worth.  
    d. What's a microservice?  
    Answer: b – Microservices are great when you have a team that is able to make use of the granularity they provide.

3. What is a monolith?
    a. A large object that appears to be made from a single piece by an unknown maker  
    b. An application that is self-contained  
    c. A system that won't run on Kubernetes  
    d. A product from a new start-up  
    Answer: b – A monolith is a self-contained application that can run quite well on Kubernetes.

4. How should you authorize access to your services in Istio?   
    a. You can write a rule that limits access in Istio by a claim in the token.   
    b. You can integrate OPA with Istio for more complex authorization decisions.   
    c. You can embed complex authorization decisions in your code.   
    d. All of the above.   
    Answer: d – These are all valid strategies from a technical standpoint. Each situation is different, so look at each one to determine which one is best for you!

5. True or false: Calling services on behalf of a user without token exchange is a secure approach.   
    a. True   
    b. False   
    Answer: b – False: Without using token exchange to get a new token for when the user the next service, you leave yourself open to various attacks because you can't limit calls or track them.

6. True or false: Istio supports sticky sessions.   
    a. True   
    b. False   
    Answer: a. True – It's not a default, but it is supported.