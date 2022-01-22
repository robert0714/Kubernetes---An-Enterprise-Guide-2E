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
kubectl apply -f ./chpater12/prometheus-deployment.yaml
kubectl apply -f ./chpater12/jaeger-deployment.yaml
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
Most monolithic applications require sticky sessions. Enabling sticky sessions means that every request in a session is sent to the same pod. This is generally not needed in microservices because each API call is distinct. Web applications that users interact with generally need to manage state, usually via cookies. Those cookies don't generally store all of the session's state though because the cookies would get too big and would likely have sensitive information. Instead, most web applications use a cookie that points to a session that's saved on the server, usually in memory. While there are ways to make sure this session is available to any instance of the application in a highly available way, it's not very common to do so. These systems are expensive to maintain and are generally not worth the work.

OpenUnison is no different than most other web applications and needs to make sure that sessions are sticky to the pod they originated from. To tell Istio how we want sessions to be managed, we use ***DestinationRule***. ***DestinationRule*** objects tell Istio what to do about traffic routed to a host by a ***VirtualService***. Here's the important parts of ours:

```yaml
spec:
  host: openunison-orchestra
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          name: openunison-orchestra
          path: /
          ttl: 0s
    tls:
      mode: ISTIO_MUTUAL
```

The ***host*** in the rule refers to the target (***Service***) of the traffic, not the hostname in the original URL. ***trafficPolicy.loadBalancer.consistentHash*** tells Istio how we want to manage stickiness. Most monolithic applications will want to use cookies. ***ttl*** is set to ***0s*** so the cookie is considered a "session cookie." This means that when the browser is closed the cookie disappears from its cookie jar.

> **⚠ ATTENTION:**  
> You should avoid cookies with specific times to live. These cookies are persisted by the browser and can be treated as a security risk by your enterprise.

With OpenUnison up and running and understanding how Istio is integrated, let's take a look at what Kiali will tell us about our monolith.

### Integrating Kiali and OpenUnison
First, let's integrate OpenUnison and Kiali. Kiali, like any other cluster management system, should be configured to require access. Kiali, just like the Kubernetes Dashboard, can integrate with Impersonation so that Kiali will interact with the API server using the user's own permissions. Doing this is pretty straight forward. We created a script in the ***chapter13*** folder called ***integrate-kiali-openunison.sh*** that:
```bash
cd chapter13
./integrate-kiali-openunison.sh
```

1. Deletes the old ***Gateway*** and ***VirtualService*** for Kiali
1. Updates the Kiali Helm Chart to use ***header*** for ***auth.strategy*** and restarts Kiali to pick up the changes
1. Deploys the openunison-kiali Helm Chart that configures OpenUnison to integrate with Kiali and adds a "badge" to the main screen of our portal
The integration works the same way as the dashboard, but if you're interested in the details you can read about them at https://openunison.github.io/applications/kiali/.

With the integration completed, let's see what Kiali can tell us about our monolith.

Next, click on the Kiali badge to open Kiali, then click on Graphs, and choose the openunison namespace. 

You can now view the connections between OpenUnison, apacheds, and other containers the same way you would with a microservice! Speaking of which, now that we've learned how to integrate a monolith into Istio, let's build a microservice and learn how it integrates with Istio.

## Building a microservice

We spent quite a bit of time talking about monoliths. First, we discussed which is the best approach for you, then we spent some time showing how to deploy a monolith into Istio to get many of the benefits from it that microservices do. Now, let's dive into building and deploying a microservice. Our microservice will be pretty simple. The goal is to show how a microservice is built and integrated into an application, rather than how to build a full-fledged application based on microservices. Our book is focused on enterprise so we're going to focus on a service that:

1. Requires authentication from a specific user
1. Requires authorization for a specific user based on a group membership or attribute
1. Does something very ***important***
1. Generates some log data about what happened

This is common in enterprise applications and the services they're built on. Most enterprises need to be able to associate actions, or decisions, to a particular person in that organization. If an order is placed, who placed it? If a case is closed, who closed it? If a check is cut, who cut it? There are of course many instances where a user isn't responsible for an action. Sometimes it's another service that is automated. A batch service that pulls in data to create a warehouse isn't associated with a particular person. This is an ***interactive*** service, meaning that an end user is expected to interact with it, so we're going to assume the user is a person in the enterprise.

Once you know who is going to use the service, you'll then need to know if the user is authorized to do so. In the previous paragraph we identified that you need to know "who cut the check?" Another important question is, "are they allowed to cut the check?" You really don't want just anybody in your organization sending out checks, do you? Identifying who is authorized to perform an action can be the subject of multiple books, so to keep things simple we'll make our authorization decisions based on group membership, at least at a high level.

Having identified the user and authorized them, the next step is to do something ***important***. It's an enterprise, filled with important things that need doing! Since writing a check is something we can all relate to and represents many of the challenges enterprise services face, we're going to stick with this as our example. We're going to write a check service that will let us send out checks.

Finally, having done something ***important***, we need to make a record of it. We need to track who called our service, and once the service does the important parts, we need to make sure we record it somewhere. This can be recorded in a database, another service, or even sent to standard-out so it can be collected by a log aggregator.

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

We'll build each of these components, layer by layer in the following sections. Before we get into the service itself, we need to say hello to the world.
### Deploying Hello World
Our first service will be a simple Hello World service that will serve as the starting point for our check-writing service. Our service is built on Python using Flask. We're using this because it's pretty simple to use and deploy. Go to chapter13/hello-world and run the deploy_helloworld.sh script. 
```bash
cd chapter13/hello-world
./deploy_helloworld.sh
```
This will create our ***Namespace***, ***Deployment***, ***Service***, and ***Istio*** objects. Look at the code in the service-source ConfigMap. This is the main body of our code and the framework on which we will build our check service. The code its self doesn't do much:
```python
@app.route('/')
def hello():
    retVal = {
        "msg":"hello world!",
        "host":"%s" % socket.gethostname()
    }
    return json.dumps(retVal)
```
This code accepts all requests to ***/*** and runs our function called ***hello()***, which sends a simple response. We're embedding our code as a ***ConfigMap*** for the sake of simplicity.

If you've read all the other chapters up to this point, you'll notice that we're violating some cardinal rules with this container from a security standpoint. It's a Docker Hub container running as root. That's OK for now. We didn't want to get bogged down in build processes for this chapter. In ***Chapter 14, Provisioning a Platform***, we'll walk through using Tekton to build out a more secure version of the container for this service.

Once our service is deployed, we can test it out by using curl:
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
curl -v http://service.$hostip.nip.io/ 
```
This code isn't terribly exciting, but next we'll add some security to our service.

### Integrating authentication into our service
In ***Chapter 12, An Introduction to Istio***, we introduced the RequestAuthentication object. Now we will use this object to enforce authentication. We want to make sure that in order to access our service, you must have a valid JWT. In the previous example, we just called our service directly. Now we want to only get a response if a valid JWT is embedded in the request. We need to make sure to pair our ***RequestAuthentication*** with an ***AuthorizationPolicy*** that forces Istio to require a JWT, otherwise Istio will only reject JWTs that don't conform to our ***RequestAuthenction*** but will allow requests that have no JWT at all.

Even before we configure our objects, we need to get a JWT from somewhere. We're going to use OpenUnison. To work with our API, let's deploy the pipeline token generation chart we deployed in ***Chapter 5, Integrating Authentication into Your Cluster***. Go to the ***chapter5*** directory and run the Helm Chart:

```bash
cd chapter5
helm install orchestra-token-api token-login -n openunison -f /tmp/openunison-values.yaml
```

This will give us a way to easily generate a JWT from our internal "Active Directory". Next, we'll deploy the actual policy objects. Go into the ***chapter13/authentication*** directory and run ***deploy-auth.sh***. It will look like:
```bash
./deploy-auth.sh
```
There are two objects that are created. The first is the ***RequestAuthentication*** object and then a simple ***AuthorizationPolicy***. First, we will walk through ***RequestAuthentication***:

```yaml
# kubectl -n istio-hello-world get requestauthentications hello-world-auth -o yaml
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  creationTimestamp: "2022-01-19T06:03:46Z"
  generation: 1
  name: hello-world-auth
  namespace: istio-hello-world
spec:
  jwtRules:
  - audiences:
    - kubernetes
    issuer: https://k8sou.192-168-57-21.nip.io/auth/idp/k8sIdp
    jwks: '{"keys...'
    outputPayloadToHeader: User-Info
  selector:
    matchLabels:
      app: run-service
```
This object first specifies how the JWT needs to be formatted in order to be accepted. We're cheating here a bit by just leveraging our Kubernetes JWT. Let's compare this object to our JWT:
```json
//  export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
//  curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token'
//  export JWT=$(curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')
//  jq -R 'split(".") | select(length > 0) | .[0],.[1] | @base64d | fromjson' <<< $JWT
{
  "iss": "https://k8sou.192-168-57-21.nip.io/auth/idp/k8sIdp",
  "aud": "kubernetes",
  "exp": 1630421193,
  "jti": "JGnXlj0I5obI3Vcmb1MCXA",
  "iat": 1630421133,
  "nbf": 1630421013,
  "sub": "mmosley",
  "name": " Mosley",
  "groups": [
    "cn=group2,ou=Groups,DC=domain,DC=com",
    "cn=k8s-cluster-admins,ou=Groups,DC=domain,DC=com"
  ],
  "preferred_username": "mmosley",
  "email": "mmosley@tremolo.dev"
}
```

The ***aud*** claim in our JWT lines up with the audiences in our ***RequestAuthentication***. The ***iss*** claim lines up with ***issuer*** in our ***RequestAuthentication***. If either of these claims don't match, then Istio will return a 401 HTTP error code to tell you the request is unauthorized.

We also specify ***outputPayloadToHeader: User-Info*** to tell Istio to pass the user info to the downstream service as a base64-encoded JSON header with the name ***User-Info***. This header can be used by our service to identify who called it. We'll get into the details of this when we get into entitlement authorization.

Additionally, the ***jwks*** section specifies the RSA public keys used to verify the JWT. This can be obtained by first going to the ***issuer***'s OIDC discovery URL and getting the URL from the ***jwks*** claim.
 
> **⚠ ATTENTION:**  
> We didn't use the ***jwksUri*** configuration option to point to our certificate URL directly because Istio would not be able to validate our self-signed certificate. The demo Istio deployment we're using would require patching the ***istiod*** ***Deployment*** to mount a certificate from a ***ConfigMap***, which we didn't want to do in this book. It is however the best way to integrate with an identity provider so if and when keys rotate, you don't need to make any updates.

It's important to note that the ***RequestAuthentication*** object will tell Istio what form the JWT needs to take, but not what data about the user needs to be present. We'll cover that next in authorization.

Speaking of authorization, we want to make sure to enforce that the requirement for a JWT, so we created this very simple ***AuthorizationPolicy***:

```yaml
# kubectl -n istio-hello-world get authorizationpolicies simple-hellow-world -o yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: simple-hellow-world
  namespace: istio-hello-world
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals:
        - '*'
  selector:
    matchLabels:
      app: run-service
```

The from section says that there must be a ***requestPrincipal***. This is telling Istio there must be a user (and in this case, anonymous is not a user). ***requestPrincipal*** comes from JWTs and represents users. There is also a principal configuration, but this represents the service calling our URL, which in this case would be ***ingressgateway***. This tells Istio a user must be authenticated via a JWT.

With our policy in place, we can now test it. First, with no user:
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
curl -v http://service.$hostip.nip.io/
```

We see that the request was denied with a 403 HTTP code. We received 403 because Istio was expecting a JWT but there wasn't one. Next, let's generate a valid token the same way we did in ***Chapter 5, Integrating Authentication into Your Cluster***:
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
curl -H "Authorization: Bearer $(curl -H "Authorization: Bearer $(curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')"  http://service.$hostip.nip.io/
```
Now a success! Our hello world service now requires proper authentication. Next, we'll update our authorization to require a specific group from Active Directory.

### Authorizing access to our service
So far, we've built a service and made sure users must have a valid JWT from our identity provider before you can access it.

Now we want to apply what's often referred to as "coarse-grained" authorization. This is application-, or service-, level access. It says "You are generally able to use this service," but it doesn't say you're able to perform the action you wish to take. For our check-writing service, you may be authorized to write a check but there's likely more controls that limit who you can write a check for. If you're responsible for the ***Enterprise Resource Planning (ERP)*** system in your enterprise you probably shouldn't be able to write checks for the facilities vendors. We'll get into how your service can manage these business-level decisions in the next section, but for now we'll focus on the service-level authorization.

It turns out we have everything we need. Earlier we looked at our mmosley user's JWT, which had multiple claims. One such claim was the groups claim. We used this claim in ***Chapter 5, Integrating Authentication into Your Cluster*** and ***Chapter 6, RBAC Policies and Auditing***, to manage access to our cluster. In a similar fashion we'll manage who can access our service based on our membership of a particular group. First, we'll delete our existing policy:
```bash
kubectl delete authorizationpolicy simple-hellow-world -n istio-hello-world
```
With the policy disabled, you can now access your service without any JWT. Next, we'll create a policy that requires you to be a member of the group cn=group2,ou=Groups,DC=domain,DC=com in our "Active Directory."

Deploy the below policy (in chapter13/coursed-grained-authorization/coursed-grained-az.yaml):
```yaml
## kubectl -n istio-hello-world get authorizationpolicies service-level-az -o yaml
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: service-level-az
  namespace: istio-hello-world
spec:
  action: ALLOW
  selector:
    matchLabels:
      app: run-service
  rules:
  - when:
    - key: request.auth.claims[groups]
      values: ["cn=group2,ou=Groups,DC=domain,DC=com"]
```

This policy tells Istio that only users with a claim called ***groups*** that has the value ***cn=group2,ou=Groups,DC=domain,DC=com*** are able to access this service. With this policy deployed you'll notice you can still access the service as mmosley, and trying to access the service anonymously still fails. Next, try accessing the service as jjackson, with the same password:
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
curl -H "Authorization: Bearer $(curl --insecure -u 'jjackson:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')"  http://service.$hostip.nip.io/
```
We're not able to access this service as ***jjackson***. If we look at ***jjackson***'s id_token, we'll see why:
```json
//  export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
//  curl --insecure -u 'jjackson:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')
//  export JWT=$(curl --insecure -u 'jjackson:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')
//  jq -R 'split(".") | select(length > 0) | .[0],.[1] | @base64d | fromjson' <<< $JWT
{
  "iss": "https://k8sou.192-168-57-21.nip.io/auth/idp/k8sIdp",
  "aud": "kubernetes",
  "exp": 1642669195,
  "jti": "PJFECkUNFX5MVAEumkKGLA",
  "iat": 1642669135,
  "nbf": 1642669015,
  "sub": "jjackson",
  "name": " Jackson",
  "groups": "cn=k8s-create-ns,ou=Groups,DC=domain,DC=com",
  "preferred_username": "jjackson",
  "email": "jjackson@tremolo.dev"
}
```
Looking at the claims, ***jjackson*** isn't a member of the group ***cn=group2,ou=Groups,DC=domain,DC=com***.

Now that we're able to tell Istio how to limit access to our service to valid users, the next step is to tell our service who the user is. We'll then use this information to look up authorization data, log actions, and act on the user's behalf.

### Telling your service who's using it
When writing a service that does anything involving a user, the first thing you need to determine is, "Who is trying to use my service?" So far, we have told Istio how to determine who the user is, but how do we propagate that information down to our service? Our ***RequestAuthentication*** included the configuration option ***outputPayloadToHeader: User-Info***, which injects the claims from our user's authentication token as base64-encoded JSON into the HTTP request's headers. This information can be pulled from that header and used by your service to look up additional authorization data.

We can view this header with a service we built, called ***/headers***. This service will just give us back all the headers that are passed to our service. Let's take a look:
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
curl  -H "Authorization: Bearer $(curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')" http://service.$hostip.nip.io/headers 2>/dev/null | jq -r '.headers' 
```

There are several headers here. The one we care about is User-Info. This is the name of the header we specified in our RequestAuthentication object. If we decode from base64, we'll get some JSON:
```json
//  export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
//  curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token'
//  export JWT=$(curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')
//  jq -R 'split(".") | select(length > 0) | .[0],.[1] | @base64d | fromjson' <<< $JWT
{
  "iss": "https://k8sou.192-168-57-21.nip.io/auth/idp/k8sIdp",
  "aud": "kubernetes",
  "exp": 1630421193,
  "jti": "JGnXlj0I5obI3Vcmb1MCXA",
  "iat": 1630421133,
  "nbf": 1630421013,
  "sub": "mmosley",
  "name": " Mosley",
  "groups": [
    "cn=group2,ou=Groups,DC=domain,DC=com",
    "cn=k8s-cluster-admins,ou=Groups,DC=domain,DC=com"
  ],
  "preferred_username": "mmosley",
  "email": "mmosley@tremolo.dev"
}
```
We have all the same claims as if we had decoded the token ourselves. What we don't have is the JWT. This is important from a security standpoint. Our service can't leak a token it doesn't possess.

Now that we know how to determine who the user is, let's integrate that into a simple ***who-am-i*** service that just tells us who the user is. First, let's look at our code:
```python
@app.route('/who-am-i')
    def who_am_i():
      user_info = request.headers["User-Info"]
      user_info_json = base64.b64decode(user_info).decode("utf8")
      user_info_obj = json.loads(user_info_json)
      ret_val = {
        "name": user_info_obj["sub"],
        "groups": user_info_obj["groups"]
      }
      return json.dumps(ret_val)
```

This is pretty basic. We're getting the header from our request. Next, we're decoding it from base64 and finally we get the JSON and add it to a return. If this were a more complex service, this is where we might query a database to determine what entitlements our user has.

In addition to not requiring that our code knows how to verify the JWT, this also makes it easier for us to develop our code in isolation from Istio. Open a shell into your run-service pod and try accessing this service directly with any user:
```bash
export PODNAME=$(kubectl -n istio-hello-world  get pods  --no-headers -o custom-columns=":metadata.name" --field-selector status.phase=Running  )
kubectl -n istio-hello-world exec -it $PODNAME  -- bash
# export USERINFO=$(echo -n '{"sub":"marc","groups":["group1","group2"]}' | base64 -w 0)
# curl -H "User-Info: $USERINFO" http://localhost:8080/who-am-i
```
We were able to call our service without having to know anything about Istio, JWTs, or cryptography! Everything was offloaded to Istio so we could focus on our service. While this does make for easier development, what are the impacts on security if there's a way to inject any information we want into our service?

Let's try this directly from a namespace that doesn't have the Istio sidecar:

```bash
kubectl run -i --tty curl --image=alpine --rm=true -- sh
/ # apk update 
/ # apk add curl
/ # curl -H "User-Info $(echo -n '{"sub":"marc","groups":["group1","group2"]}' | base64 -w 0)" http://run-service.istio-hello-world.svc/who-am-i

RBAC: access denied/ #
```

Our ***RequestAuthentication*** and ***AuthorizationPolicy*** stop the request. While we're not running the sidecar, our service is, and redirects all traffic to Istio where our policies will be enforced. What about if we try to inject our own User-Info header from a valid request?
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
export USERINFO=$(echo -n '{"sub":"marc","groups":["group1","group2"]}' | base64 -w 0)
curl  -H "Authorization: Bearer $(curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')" -H "User-Info: $USERINFO" http://service.$hostip.nip.io/who-am-i
{"name": "mmosley", "groups": ["cn=group2,ou=Groups,DC=domain,DC=com", "cn=k8s-cluster-admins,ou=Groups,DC=domain,DC=com"]}
```
or 
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
export USERINFO=$(echo -n '{"sub":"marc","groups":["group1","group2"]}' | base64 -w 0)
curl  -H "Authorization: Bearer $(curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user  | jq -r '.token.id_token')" -H "User-Info: $USERINFO" http://service.$hostip.nip.io/who-am-i
{"name": "mmosley", "groups": ["cn=group2,ou=Groups,DC=domain,DC=com", "cn=k8s-cluster-admins,ou=Groups,DC=domain,DC=com"]}
```
Once again, our attempt to override who the user is outside of a valid JWT has been foiled by Istio. We've shown how Istio injects the user's identity into our service, now we need to know how to authorize a user's entitlements.
### Authorizing user entitlements
So far, we've managed to add quite a bit of functionality to our service without having to write any code. We added token-based authentication and coarse-grained authorization. We know who the user is and have determined that at the service level, they are authorized to call our service. Next, we need to decide if the user is allowed to do the specific action they're trying to do. This is often called fine-grained authorization or entitlements. In this section, we'll walk through multiple approaches you can take, and discuss how you should choose an approach.
#### Authorizing in service
Unlike coarse-grained authorizations and authentication, entitlements are generally not managed at the service mesh layer. That's not to say it's impossible. We'll talk about ways you can do this in the service mesh but in general, it's not the best approach. Authorizations are generally tied to business data that's usually locked up in a database. Sometimes that database is a generic relational database like MySQL or SQL Server, but it could really be anything. Since the data used to make the authorization decision is often owned by the service owner, not the cluster owner, it's generally easier and more secure to make entitlement decisions directly in our code.

Earlier, we discussed in our check-writing service that we don't want someone responsible for the ERP to cut checks to the facilities vendor. Where is the data that determines that? Well, it's probably in your enterprise's ERP system. Depending on how big you are, this could be a home-grown application all the way up to SAP or Oracle. Let's say you wanted Istio to make the authorization decision for our check-writing service. How would it get that data? Do you think the people responsible for the ERP want you, as a cluster owner, talking to their database directly? Do you, as a cluster owner, want that responsibility? What happens when something goes wrong with the ERP and someone points the finger at you for the problem? Do you have the resources to prove that you, and your team, were not responsible?

It turns out the silos in enterprises that benefit from the management aspects of microservice design also work against centralized authorization. In our example of determining who can write the check for a specific vendor, it's probably just easiest to make this decision inside our service. This way, if there's a problem it's not the Kubernetes team's responsibility to determine the issue and the people who are responsible are in control of their own destiny.

That's not to say there isn't an advantage to a more centralized approach to authorization. Having teams implement their own authorization code will lead to different standards being used and different approaches. Without careful controls, it can lead to a compliance nightmare. Let's look at how Istio could provide a more robust framework for authorization.
#### Using OPA with Istio
Using the Envoy filters feature discussed in Chapter 12, An Introduction to Istio, you can integrate the Open Policy Agent (OPA) into your service mesh to make authorization decisions. We discussed OPA in Chapter 8, Extending Security Using Open Policy Agent. There are a few key points about OPA we need to review:

* OPA does not (typically) reach out to external data stores to make authorization decisions. Much of the benefit of OPA requires that it uses its own internal database.
* OPA's database is not persistent. When an OPA instance dies, it must be repopulated with data.
* OPA's databases are not clustered. If you have multiple OPA instances, each database must be updated independently.

To use OPA to validate whether our user can write a check for a specific vendor, OPA would either need to be able to pull that data directly from the JWT or have the ERP data replicated into its own database. The former is unlikely to happen for multiple reasons. First, the issues with your cluster talking to your ERP will still exist when your identity provider tries to talk to your ERP. Second, the team that runs your identity provider would need to know to include the correct data, which is a difficult ask and is unlikely to be something they're interested in doing. Finally, there could be numerous folks from security to the ERP team who are not comfortable with this data being stored in a token that gets passed around. The latter, syncing data into OPA, is more likely to be successful.

There are two ways you could sync your authorization data from your ERP into your OPA databases. The first, is you could push the data. A "bot" could push updates to each OPA instance. This way, the ERP owner is responsible for pushing the data with your cluster just being a consumer. There's no simple way to do this though and security would be a concern to make sure someone doesn't push in false data. The alternative is to write a pull "bot" that runs as a sidecar to your OPA pods. This is how GateKeeper works. The advantage here is that you have the responsibility of keeping your data synced without having to build a security framework for pushing data.

In either scenario, you'll need to understand whether there are any compliance issues with the data you are storing. Now that you have the data, what's the impact of losing it in a breach? Is that a responsibility you want?

Centralized authorization services have been discussed for entitlements long before Kubernetes or even RESTful APIs existed. They even predate SOAP and XML! For enterprise applications, it's never really worked because of the additional costs in data management, ownership, and bridging silos. If you own all of the data, this is a great approach. When one of the main goals of microservices is to allow silos to better manage their own development, forcing a centralized entitlements engine is not likely to succeed.

Having determined how to integrate entitlements into our services, the next question we need to answer is, how do we call other services?
### Calling other services
We've written services that do simple things, but what about when your service needs to talk to another service? Just like with almost every other set of choices in your cluster rollout, you have multiple options for authenticating to other services. Which choice you make will depend on your needs. We'll first cover the OAuth2 standard way of getting new tokens for service calls and how Istio works with it. We'll then cover some alternatives that should be considered anti-patterns but that you may choose to use anyway.
#### Using OAuth2 Token Exchange
Your service knows who your user is, but needs to call another service. How do you identify yourself to the second service? The OAuth2 specification, which OpenID Connect is built on, has RFC 8693 – OAuth2 Token Exchange for this purpose. The basic idea is that your service will get a fresh token from your identity provider for the service call based on the existing user. By getting a fresh token for your own call to a remote service, you're making it easier to lock down where tokens can be used and who can use them, and allowing yourself to more easily track a call's authentication and authorization flow.

There are some details we'll walk through that depend on your use case:

1. The user requests an **id_token** from the identity provider. How the user gets their token doesn't really matter for this part of the sequence. We'll use a utility in OpenUnison for our lab.
1. Assuming you're authenticated and authorized, your identity provider will give you an **id_token** with an **aud** claim that will be accepted by Service-X.
1. The user uses the **id_token** as a bearer token for calling Service-X. It goes without saying that Istio will validate this token.
1. Service-X requests a token for Service-Y from the identity provider on behalf of the user. There are two potential methods to do this. One is impersonation, the other is delegation. We'll cover both in detail later in this section. You'll send your identity provider your original **id_token** and something to identify the service to the identity provider.
1. Assuming Service-X is authorized, the identity provider sends a new **id_token** to Service-X with the original user's attributes and an **aud** scoped to Service-Y.
1. Service-X uses the new **id_token** as the Authorization header when calling Service-Y. Again, Istio is validating the **id_token**.   

Steps 7 and 8 in the previous diagram aren't really important here.

If you think this seems like quite a bit of work to make a service call, you're right. There are several authorization steps going on here:

1. The identity provider is authorizing that the user can generate a token scoped to Service-X
1. Istio is validating the token and that it's properly scoped to Service-X
1. The identity provider is authorizing that Service-X can get a token for Service-Y and that it's able to do so for our user
1. Istio is validating that the token used by Service-X for Service-Y is properly scoped

These authorization points provide a chance for an improper token to be stopped, allowing you to create very short-lived tokens that are harder to abuse and are more narrowly scoped. For instance, if the token used to call Service-X were leaked, it couldn't be used to call Service-Y on its own. You'd still need Service-X's own token before you could get a token for Service-Y. That's an additional step an attacker would need to take in order to get control of Service-Y. It also means breaching more than one service, providing multiple layers of security. This lines up with our discussion of defense in depth from Chapter 8, Extending Security Using Open Policy Agent. With a high-level understanding of how OAuth2 Token Exchange works, the next question we need to answer is how will your services authenticate themselves to your identity provider?
##### Authenticating your service
In order for the token exchange to work, your identity provider needs to know who the original user is and which service wants to exchange the token on behalf of the user. In the check-writing service example we've been discussing, you wouldn't want the service that provides today's lunch menu to be able to generate a token for issuing a check! You accomplish this by making sure your identity provider knows the difference between your check-writing services and your lunch menu service by authenticating each service individually.

There are three ways a service running in Kubernetes can authenticate itself to the identity provider:

1. Use the Pod's ***ServiceAccount*** token
1. Use Istio's mTLS capabilities
1. Use a pre-shared "client secret"

Throughout the rest of this section, we're going to focus on option #1, using the Pod's built-in ***ServiceAccount*** token. This token is provided by default for each running Pod. This token can be validated by either submitting it to the API server's ***TokenReview*** service or by treating it as a JWT and validating it against the public key published by the API server.

In our examples, we're going to use the ***TokenReview*** API to test the passed-in ***ServiceAccount*** token against the API server. This is the most backward-compatible approach and supports any kind of token integrated into your cluster. For instance, if you're deployed in a managed cloud with its own IAM system that mounts tokens, you could use that as well. This could generate a considerable amount of load on your API server, since every time a token needs to be validated it gets sent to the API server.

The ***TokenRequest*** API discussed in Chapter 5, Integrating Authentication into Your Cluster, can be used to cut down on this additional load. Instead of using the ***TokenReview*** API we can call the API server's issuer endpoint to get the appropriate token verification public key and use that key to validate the token's JWT. While this is convenient and scales better, it does have some drawbacks:

1. Starting in 1.21, ***ServiceAccount*** tokens are mounted using the ***TokenRequest*** API, but with lifespans of a year or more. You can manually change this to be as short as 10 minutes.
1. Validating the JWT directly against a public key won't tell you if the Pod is still running. The ***TokenReview*** API will fail if a ***ServiceAcount*** token is associated with a deleted ***Pod***, adding an additional layer of security.

We're not going to use Istio's mTLS capabilities because it's not as flexible as tokens. It's primarily meant for intra-cluster communications, so if our identity provider were outside of the cluster, it would be much harder to use. Also, since mTLS requires a point-to-point connection, any TLS termination points would break its use. Since it's rare for an enterprise system to host its own certificate, even outside of Kubernetes, it would be very difficult to implement mTLS between your cluster's services and your identity provider.

Finally, we're not going to use a shared secret between our services and our identity provider because we don't need to. Shared secrets are only needed when you have no other way to give a workload an identity. Since Kubernetes gives every Pod its own identity, there's no need to use a client secret to identify our service.

Now that we know how our services will identify themselves to our identity provider, let's walk through an example of using OAuth2 Token Exchange to securely call one service from another.
##### Deploying and running the check-writing service
Having walked through much of the theory of using a token exchange to securely call services, let's deploy an example check-writing service. When we call this service, it will call two other services. The first service, ***check-funds***, will use the impersonation profile of OAuth2 Token Exchange while the second service, ***pull-funds***, will use delegation. We'll walk through each of these individually. First, use Helm to deploy an identity provider. Go into the ***chapter13*** directory and run:

```bash
helm -n openunison install openunison-service-auth openunison-service-auth
```
We're not going to go into the details of OpenUnison's configuration. Suffice to say this will set up an identity provider for our services and a way to get an initial token. Next, deploy the write-checks service:

```bash
cd write-checks/
./deploy_write_checks.sh`
```
This should look pretty familiar after the first set of examples in this chapter. We deployed our service as Python in a ConfigMap and the same Istio objects we created in the previous service. The only major difference is in our RequestAuthentication object:
```yaml
## kubectl -n write-checks get requestauthentications write-checks-auth -o yaml
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:  
  name: write-checks-auth
  namespace: write-checks
spec:
  jwtRules:
  - audiences:
    - users
    - checkfunds
    - pullfunds
    forwardOriginalToken: true
    issuer: https://k8sou.192-168-57-21.nip.io/auth/idp/service-idp
    jwks: '{"keys"....'
    outputPayloadToHeader: User-Info
  selector:
    matchLabels:
      app: write-checks
```
There's an additional setting, ***forwardOriginalToken***, that tells Istio to send the service the original JWT used to authenticate the call. We'll need this token in order to prove to the identity provider we should even attempt to perform a token exchange. You can't ask for a new token if you can't provide the original. This keeps someone with access to your service's Pod from requesting a token on your behalf with just the service's ***ServiceAccount***.

Earlier in the chapter we said we couldn't leak a token we didn't have, so we shouldn't have access to the original token. This would be true if we didn't need it to get a token for another service. Following the concept of least privilege, we shouldn't forward the token if we don't need to. In this case, we need it for a token exchange so it's worth the increased risk to have more secure service-to-service calls.

With our example check-writing service deployed, let's run it and work backward. Just like with our earlier examples, we'll use ***curl*** to get the token and call our service. In ***chapter13/write-checks***, run ***call_service.sh***:
```bash
export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')
export JWT=$(curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')
curl -v  -H "Authorization: Bearer $JWT" http://write-checks.$hostip.nip.io/write-check
curl -v  -H "Authorization: Bearer $JWT" http://write-checks.$hostip.nip.io/write-check  2>/dev/null  | jq -r
```
If istio sucessfully authenticate the JWT  the ouput is :
```json
{
  "msg": "hello world!",
  "host": "write-checks-84cdbfff74-tgmzh",
  "user_jwt": "...",
  "pod_jwt": "...",
  "impersonated_jwt": "...",
  "call_funds_status_code": 200,
  "call_funds_text": "{\"funds_available\": true, \"user\": \"mmosley\"}",
  "actor_token": "...",
  "delegation_token": "...",
  "pull_funds_text": "{\"funds_pulled\": true, \"user\": \"mmosley\", \"actor\": \"system:serviceaccount:write-checks:default\"}"
}
```
If it failed , the ouput is :
```bash
Jwt issuer is not configured
```

The output you see is the result of the calls to /write-check, which then calls /check-funds and /pull-funds. Let's walk through each call, the tokens that are generated, and the code that generates them.

##### Using Impersonation
We're not talking about the same Impersonation you used in Chapter 5, Integrating Authentication into Your Cluster. It's a similar concept, but this is specific to token exchange. When /write-check needs to get a token to call /check-funds, it asks OpenUnison for a token on behalf of our user, mmosley. The important aspect of Impersonation is that there's no reference to the requesting client in the generated token. The /check-funds service has no knowledge that the token it's received wasn't retrieved by the user themselves. Working backward, the impersonated_jwt in the response to our service call is what /write-check used to call /check-funds. Here's the payload after dropping the result into jwt.io:
```json
{
  "iss": "https://k8sou.192-168-2-119.nip.io/auth/idp/service-idp",
  "aud": "checkfunds",
  "exp": 1631497059,
  "jti": "C8Qh8iY9FJdFzEO3pLRQzw",
  "iat": 1631496999,
  "nbf": 1631496879,
  "nonce": "bec42c16-5570-4bd8-9038-be30fd216016",
  "sub": "mmosley",
  "name": " Mosley",
  "groups": [
    "cn=group2,ou=Groups,DC=domain,DC=com",
    "cn=k8s-cluster-admins,ou=Groups,DC=domain,DC=com"
  ],
  "preferred_username": "mmosley",
  "email": "mmosley@tremolo.dev",
  "amr": [
    "pwd"
  ]
}
```

The two important fields here are sub and aud. The sub field tells /check-funds who the user is and the aud field tells Istio which services can consume this token. Compare this to the payload from the original token in the user_jwt response:
```json
{
  "iss": "https://k8sou.192-168-2-119.nip.io/auth/idp/service-idp",
  "aud": "users",
  "exp": 1631497059,
  "jti": "C8Qh8iY9FJdFzEO3pLRQzw",
  "iat": 1631496999,
  "nbf": 1631496879,
  "sub": "mmosley",
  "name": " Mosley",
  "groups": [
    "cn=group2,ou=Groups,DC=domain,DC=com",
    "cn=k8s-cluster-admins,ou=Groups,DC=domain,DC=com"
  ],
  "preferred_username": "mmosley",
  "email": "mmosley@tremolo.dev",
  "amr": [
    "pwd"
  ]
}
```
The original sub is the same, but the aud is different. The original aud is for users while the impersonated aud is for checkfunds. This is what differentiates the impersonated token from the original one. While our Istio deployment is configured to accept both audiences for the same service, that's not a guarantee in most production clusters. When we call /check-funds, you'll see that in the output we echo the user of our token, mmosley.

Now that we've seen the end product, let's see how we get it. First, we get the original JWT that was used to call /write-check:

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
