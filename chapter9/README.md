# Chapter 9 Node Security with GateKeeper
## Technical requirements
chapter2 -> chapter6 -> chpter 8

```bash
./chapter2/create-cluster.sh
./chapter6/deploy_openunison_imp.sh
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.5/deploy/gatekeeper.yaml
kubectl apply -f ./chapter8/simple-opa-policy/yaml/gatekeeper-policy-template.yaml
```
## Enforcing node security with GateKeeper

### Deploying and debugging node security policies

Having gone through much of the theory in building node security policies in GateKeeper, let's dive into locking down our test cluster. The first step is to clean out our cluster. The easiest way to do this is to just remove GateKeeper and redeploy:
```bash
kubectl delete -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.5/deploy/experimental/gatekeeper-mutation.yaml
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.5/deploy/experimental/gatekeeper-mutation.yaml
```

#### Generating security context defaults

For this chapter, I took them and tweaked them a bit. Let's deploy them, and then recreate all our pods so that they have our "sane defaults" in place before rolling out our constraint implementations:
```bash
kubectl create -f chapter9/default_mutations.yaml
sh chapter9/delete_all_pods_except_gatekeeper.sh
```
With our pods deleted and recreated, we can check to see whether the pods running in the openunison namespace have a default securityContext configuration:

```bash
kubectl get pod -o jsonpath='{$.items[0].spec.containers[0].securityContext}' -l app=openunison-operator -n openunison | jq -r
```

#### Enforcing cluster policies
```bash
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper-library/master/library/pod-security-policy/allow-privilege-esca
lation/template.yaml
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper-library/master/library/pod-security-policy/forbidden-sysctls/template.yaml
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper-library/master/library/pod-security-policy/host-filesystem/template.yaml
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper-library/master/library/pod-security-policy/host-namespaces/template.yaml
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper-library/master/library/pod-security-policy/host-network-ports/template.yaml
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper-library/master/library/pod-security-policy/privileged-containers/template.yaml
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper-library/master/library/pod-security-policy/proc-mount/template.yaml
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper-library/master/library/pod-security-policy/users/template.yaml 
kubectl apply -f chapter9/minimal_gatekeeper_constraints.yaml
```