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
```