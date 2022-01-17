# Chapter 8 Extending Security Using Open Policy Agent

## Using Rego to write policies

### Deploying policies to Gatekeeper

show constraint violations
```bash
for constraint in $(kubectl get crds | grep 'constraints.gatekeeper.sh' | awk '{print $1}');
do      
        echo "$constraint $(kubectl get $constraint -o json | jq -r '.items[0].status.totalViolations')"
done
```


show constraint violations
```bash
 kubectl get k8spspallowprivilegeescalationcontainer.constraints.gatekeeper.sh -o jsonpath='{$.items[0].status.violations}' | jq -r
[
  {
    "enforcementAction": "deny",
    "kind": "Pod",
    "message": "Privilege escalation container is not allowed: controller",
    "name": "ingress-nginx-controller-79b67cf4c-6x8hk",
    "namespace": "ingress-nginx"
  },
  {
    "enforcementAction": "deny",
    "kind": "Pod",
    "message": "Privilege escalation container is not allowed: local-path-provisioner",
    "name": "local-path-provisioner-547f784dff-q8458",
    "namespace": "local-path-storage"
  }
]
```

show constraint violations
```bash
 kubectl get k8spspcapabilities.constraints.gatekeeper.sh -o jsonpath='{$.items[0].status.violations}' | jq -r
[
  {
    "enforcementAction": "deny",
    "kind": "Pod",
    "message": "container <controller> has a disallowed capability. Allowed capabilities are []",
    "name": "ingress-nginx-controller-79b67cf4c-6x8hk",
    "namespace": "ingress-nginx"
  },
  {
    "enforcementAction": "deny",
    "kind": "Pod",
    "message": "container <local-path-provisioner> is not dropping all required capabilities. Container must drop all of [\"all\"] or \"ALL\"",
    "name": "local-path-provisioner-547f784dff-q8458",
    "namespace": "local-path-storage"
  }
]
```