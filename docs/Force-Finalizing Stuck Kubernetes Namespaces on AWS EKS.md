# Force-Finalizing Stuck Kubernetes Namespaces on AWS EKS

Nov 2, 2026 · @Machindra

Your EKS cluster teardown is stuck. `kubectl delete ns my-namespace` has been running for 10 minutes. The namespace shows `Terminating` and refuses to go away. This guide explains why it happens, what force-finalize actually does, and how to fully clean up an AWS EKS cluster — from stuck namespaces to orphaned VPCs.

## What Is a Finalizer?

A **finalizer** is a metadata string on a Kubernetes object that acts as a **deletion gate**. Kubernetes will not permanently delete an object until every finalizer on it has been removed.

Think of it like a checklist that must be cleared before checkout:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  finalizers:
  - kubernetes                          # built-in namespace finalizer
  - elbv2.k8s.aws/resources             # AWS Load Balancer Controller
  - service.k8s.aws/resources           # AWS Service Controller
```

The namespace above has three finalizers. Kubernetes will hold the object in `Terminating` state until all three are removed. Each finalizer is "owned" by a controller — a piece of software running in the cluster that watches for objects being deleted and performs cleanup before removing the finalizer string.

**Why do finalizers exist?**

They prevent orphaned cloud resources. When you delete a Kubernetes `Service` of type `LoadBalancer`, the AWS Load Balancer Controller needs to delete the actual AWS Network Load Balancer first. The finalizer ensures the NLB is gone before Kubernetes cleans up its own records. Without finalizers, you'd have dangling AWS resources with no way to find which cluster created them.

**Common finalizers you'll encounter on AWS EKS:**

| Finalizer | Owner Controller | What it cleans up |
| --- | --- | --- |
| `kubernetes` | kube-controller-manager | Namespace contents (pods, services, etc.) |
| `elbv2.k8s.aws/resources` | AWS Load Balancer Controller | Target groups, listener rules |
| `service.k8s.aws/resources` | AWS Service Controller | NLB resources |
| `foregroundDeletion` | garbage-collector | Child objects in foreground cascade |
| `orphan` | garbage-collector | Marks children as orphaned, not deleted |

## The Kubernetes Deletion Lifecycle

When you run `kubectl delete ns my-namespace`, here is exactly what happens:

1. **kubectl sends a DELETE request** to the Kubernetes API server for the namespace object.
2. **API server sets `deletionTimestamp`** on the object — a timestamp marking when deletion was requested. The object is now in `Terminating` state.
3. **API server does NOT delete the object yet.** It checks for finalizers. If any exist, it waits.
4. **Each owning controller sees the `deletionTimestamp`** and starts its cleanup work (deleting the AWS NLB, removing target groups, etc.).
5. **Each controller removes its own finalizer** from the object's metadata once cleanup is done.
6. **Once all finalizers are removed**, the API server permanently deletes the object from etcd.

```
kubectl delete ns  →  deletionTimestamp set  →  controllers clean up
                                                        ↓
                       object deleted from etcd  ←  finalizers all removed
```

The critical point: **the object exists in etcd as long as any finalizer remains**. If a controller crashes, is deleted, or its cleanup fails, that finalizer stays on the object forever. The namespace is stuck `Terminating` indefinitely — and there is no timeout built into Kubernetes for this.

**What `kubectl get ns` looks like when stuck:**

```bash
$ kubectl get ns
NAME               STATUS        AGE
default            Active        8h
kube-system        Active        8h
my-namespace       Terminating   47m   # stuck here
```

The `AGE` keeps climbing. The namespace will never delete on its own.

## Why Namespaces Get Stuck on AWS EKS

The root cause is always the same: **a finalizer remains on an object, but the controller that owns it no longer exists to remove it.**

This happens most often during cluster teardown when you delete controllers before cleaning up the resources they manage.

**The most common AWS EKS scenario: AWS Load Balancer Controller**

If you installed the AWS Load Balancer Controller to manage NLBs and ALBs, it attaches finalizers to resources like `TargetGroupBinding`:

```bash
$ kubectl get targetgroupbindings -n my-namespace -o yaml
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  finalizers:
  - elbv2.k8s.aws/resources    # <-- owned by AWS LB Controller
  - service.k8s.aws/resources  # <-- also AWS LB Controller
```

If you then delete the AWS Load Balancer Controller (for example, by `helm uninstall aws-load-balancer-controller`) **before** deleting your `Service` objects, you get:

- The `TargetGroupBinding` still has those finalizers
- The controller that would remove them is gone
- The namespace cannot finish terminating
- The namespace is stuck forever

**Other common causes on EKS:**

| Cause | Stuck Object | Orphaned Finalizer |
| --- | --- | --- |
| LB Controller deleted before Services | `TargetGroupBinding` | `elbv2.k8s.aws/resources` |
| Operator/CRD controller deleted | Custom resources | Operator-specific finalizers |
| cert-manager deleted before certs | `Certificate` objects | `cert-manager.io/certificate-exists` |
| Velero deleted | `Backup` objects | `velero.io/backup-finalizer` |
| Karpenter deleted | `Provisioner` objects | Karpenter-specific finalizers |

**The diagnostic command:**

```bash
# See what's blocking namespace deletion
kubectl get namespace my-namespace -o json | \
  jq '.status.conditions[] | select(.type=="NamespaceContentRemaining")'
```

Output tells you exactly what's left inside the namespace — pods, services, custom resources — and which finalizers are blocking them.

## What Force-Finalize Actually Does

Force-finalize is **not a kubectl command** — it's a pattern: you manually patch an object to remove all its finalizers, bypassing the controller-based cleanup process entirely.

The command for a namespace looks like this:

```bash
kubectl get namespace my-namespace -o json \
  | jq 'del(.spec.finalizers[])' \
  | kubectl replace --raw "/api/v1/namespaces/my-namespace/finalize" -f -
```

**What each part does:**

- `kubectl get namespace my-namespace -o json` — fetch the namespace as JSON
- `jq 'del(.spec.finalizers[])'` — remove all entries from the `spec.finalizers` array (sets it to `[]`)
- `kubectl replace --raw "/api/v1/namespaces/my-namespace/finalize" -f -` — send the modified object directly to the namespace finalize endpoint

**The finalize endpoint** (`/api/v1/namespaces/<name>/finalize`) is a special Kubernetes API endpoint that **only** updates `spec.finalizers` — it ignores everything else in the payload. Writing an empty array to it tells Kubernetes: "all finalizers are satisfied."

Once Kubernetes sees `spec.finalizers: []`, it removes the `deletionTimestamp` block from etcd and permanently deletes the namespace object.

**Critical distinction:** Force-finalize tells Kubernetes the cleanup is done. It does **not** actually do the cleanup. If the AWS Load Balancer Controller was supposed to delete an NLB before removing its finalizer, and you force-finalize instead, **the NLB still exists in AWS** — it just has no Kubernetes record attached to it. You now have an orphaned cloud resource that will keep billing you until you find and delete it manually.

> **Force-finalize is a last resort, not a first step.** Use it only when the controller is already gone and cannot do its own cleanup.

## Step-by-Step: How to Force-Finalize a Stuck Namespace

### Step 1 — Confirm the namespace is stuck

```bash
kubectl get ns | grep Terminating
# sre-ai-agent   Terminating   23m
```

### Step 2 — Find out what's blocking it

```bash
kubectl get namespace sre-ai-agent -o json | \
  jq '.status.conditions'
```

Look for `NamespaceContentRemaining` or `NamespaceFinalizersRemaining`. The message field tells you what objects are left and which finalizers are holding them.

### Step 3 — Try to delete the blocking objects first

Before force-finalizing, try to delete the stuck resources normally:

```bash
# List all resources in the namespace
kubectl api-resources --verbs=list --namespaced -o name | \
  xargs -I{} kubectl get {} -n sre-ai-agent 2>/dev/null

# If you see TargetGroupBindings or similar:
kubectl delete targetgroupbinding --all -n sre-ai-agent

# Force-delete stuck pods:
kubectl delete pods --all -n sre-ai-agent --force --grace-period=0
```

### Step 4 — Patch finalizers off individual objects (if needed)

If a specific resource has orphaned finalizers, patch them directly:

```bash
# Patch a TargetGroupBinding to remove its finalizers
kubectl patch targetgroupbinding <name> -n sre-ai-agent \
  --type=json \
  -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Or use merge patch:
kubectl patch targetgroupbinding <name> -n sre-ai-agent \
  --type=merge \
  -p='{"metadata":{"finalizers":null}}'
```

### Step 5 — Force-finalize the namespace

Once the blocking resources are cleared (or if the namespace itself has orphaned finalizers):

```bash
kubectl get namespace sre-ai-agent -o json \
  | jq 'del(.spec.finalizers[])' \
  | kubectl replace --raw "/api/v1/namespaces/sre-ai-agent/finalize" -f -
```

If successful, you'll see the full namespace JSON returned. Then confirm it's gone:

```bash
kubectl get ns sre-ai-agent
# Error from server (NotFound): namespaces "sre-ai-agent" not found
```

**That "NotFound" is exactly what you want.** The namespace is deleted.

### Step 6 — Check for orphaned AWS resources

After force-finalizing, always verify that cloud resources were actually cleaned up:

```bash
# Check for orphaned NLBs
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?contains(LoadBalancerName, `my-cluster`)].{Name:LoadBalancerName,ARN:LoadBalancerArn,State:State.Code}'

# Check for orphaned target groups
aws elbv2 describe-target-groups \
  --query 'TargetGroups[?contains(TargetGroupName, `my-cluster`)].TargetGroupName'
```

Delete anything that remains before tearing down the VPC.

## The AWS-Specific Problem: Load Balancers, ENIs, and VPCs

Force-finalizing the Kubernetes namespace is only half the battle on AWS EKS. The real pain comes after — when CloudFormation fails to delete the VPC because AWS resources created by Kubernetes are still alive.

### Network Load Balancers (NLBs) block VPC deletion

Every `Service` of type `LoadBalancer` creates an AWS NLB. When you force-finalize the namespace, Kubernetes drops its records but the NLB still exists in AWS. NLBs attach to your VPC subnets via ENI (Elastic Network Interface) attachments. CloudFormation cannot delete the subnet while an ENI is attached to it — and it cannot delete the VPC while the subnet exists.

Result: `eksctl delete cluster` finishes, but CloudFormation is stuck in `DELETE_FAILED`:

```
SubnetPublicAPSOUTH1A    DELETE_FAILED   DependencyViolation
SubnetPublicAPSOUTH1B    DELETE_FAILED   DependencyViolation
VPCGatewayAttachment     DELETE_FAILED   DependencyViolation
```

**How to find orphaned NLBs:**

```bash
# List NLBs tagged with your cluster name
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].{Name:LoadBalancerName,ARN:LoadBalancerArn,VPC:VpcId}' \
  --output table

# Or by VPC ID:
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='vpc-xxxxxxxxx'].LoadBalancerArn" \
  --output text
```

**Delete them:**

```bash
aws elbv2 delete-load-balancer \
  --load-balancer-arn arn:aws:elasticloadbalancing:ap-south-1:123456789:loadbalancer/net/k8s-sreaiage-abc123/xyz
```

### `ela-attach` ENIs — the ones you cannot delete

When inspecting your VPC's ENIs, you may see interfaces with description `"amazon-eks-..."` and request type `"ela-attach"`. These are EKS control plane ENIs — AWS-managed network interfaces that connect the EKS control plane to your VPC.

```bash
$ aws ec2 delete-network-interface --network-interface-id eni-xxx
# An error occurred (OperationNotPermitted): You do not have permission to
# manage 'ela-attach' attachment type network interfaces.
```

**Do not try to delete these.** They are owned by AWS and will be released automatically when the CloudFormation stack finishes deleting the control plane. There is no manual action required or possible.

### Security groups block VPC deletion

Kubernetes also creates security groups for load balancers and node communication. These must be deleted before the VPC can be removed.

```bash
# Find security groups in the VPC (exclude the default one)
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=vpc-xxxxxxxxx" \
  --query 'SecurityGroups[?GroupName!=`default`].{ID:GroupId,Name:GroupName}'

# Delete them one by one
aws ec2 delete-security-group --group-id sg-xxxxxxxxx
```

If a security group delete fails with `DependencyViolation`, there is still an ENI referencing it. Find and delete that ENI first, or wait for the NLB deletion to propagate (can take 1–2 minutes).

## Complete EKS Teardown Playbook

Follow this order to avoid stuck namespaces and orphaned AWS resources. The sequence matters — each step removes a dependency for the next.

**Phase 1: Delete Kubernetes workloads (before any infrastructure)**

```bash
# 1. Delete Services (allows LB Controller to clean up NLBs while it's still running)
kubectl delete svc --all -n my-namespace --wait=true

# 2. Delete Deployments, StatefulSets
kubectl delete deploy,sts,ds --all -n my-namespace

# 3. Delete any CRDs' custom resources
kubectl delete targetgroupbinding,ingressclassparams --all -n my-namespace

# 4. Delete the namespace normally (wait for it)
kubectl delete ns my-namespace --timeout=120s
```

**Phase 2: Delete controllers (after their managed resources are gone)**

```bash
# Uninstall AWS Load Balancer Controller AFTER services are deleted
helm uninstall aws-load-balancer-controller -n kube-system

# Uninstall any other controllers (cert-manager, external-dns, etc.)
helm uninstall cert-manager -n cert-manager
```

**Phase 3: If namespaces are stuck, force-finalize**

```bash
# For each stuck namespace:
NS="my-namespace"

# Check what's blocking
kubectl get namespace $NS -o json | jq '.status.conditions'

# Patch finalizers off any blocking resources
kubectl get namespace $NS -o json \
  | jq 'del(.spec.finalizers[])' \
  | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f -
```

**Phase 4: Delete the cluster**

```bash
exsctl delete cluster --name my-cluster --region ap-south-1
```

This triggers the CloudFormation stack deletion. Watch it:

```bash
aws cloudformation describe-stack-events \
  --stack-name eksctl-my-cluster-cluster \
  --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output table
```

**Phase 5: Manual AWS cleanup if CloudFormation fails**

```bash
# 1. Find and delete orphaned NLBs
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(VpcId,'vpc-xxx')].LoadBalancerArn" \
  --output text | xargs -I{} aws elbv2 delete-load-balancer --load-balancer-arn {}

# Wait 60 seconds for NLB ENIs to detach
sleep 60

# 2. Delete subnets
for SUBNET in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-xxx" \
  --query 'Subnets[].SubnetId' --output text); do
  aws ec2 delete-subnet --subnet-id $SUBNET
done

# 3. Detach and delete internet gateway
IGW=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=vpc-xxx" \
  --query 'InternetGateways[0].InternetGatewayId' --output text)
aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id vpc-xxx
aws ec2 delete-internet-gateway --internet-gateway-id $IGW

# 4. Delete non-default security groups
for SG in $(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=vpc-xxx" \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
  aws ec2 delete-security-group --group-id $SG
done

# 5. Delete the VPC
aws ec2 delete-vpc --vpc-id vpc-xxx
```

## What Can Go Wrong

**1. Orphaned cloud resources after force-finalize**

This is the most dangerous outcome. If you force-finalize before the controller cleans up, AWS resources persist invisibly — NLBs, target groups, security groups. They bill you and block future VPC deletion. Always run the AWS CLI checks after force-finalizing.

**2. CloudFormation DELETE\_FAILED is not fatal**

A `DELETE_FAILED` stack does not mean the cluster is still running. It usually means one dependency (a subnet, a security group) could not be deleted because of an orphaned resource. The EKS control plane itself may be gone. Clean up the AWS dependency manually and the stack will finish.

**3. `eksctl delete cluster` exits successfully but VPC remains**

`eksctl` considers its job done when the stack deletion starts — it does not always wait for full completion. Always verify the VPC is actually gone:

```bash
aws ec2 describe-vpcs --vpc-ids vpc-xxx
# Should return: An error occurred (InvalidVpcID.NotFound)
```

**4. The `ela-attach` ENIs block subnet deletion temporarily**

Even after NLBs are deleted, EKS control plane ENIs (`ela-attach` type) remain until CloudFormation finishes deleting the control plane stack. If you delete NLBs and immediately try to delete subnets, you may still see `DependencyViolation`. Wait 1–2 minutes and retry.

**5. Force-finalizing a namespace with running pods**

If pods are still running inside the namespace when you force-finalize the namespace itself, the pods become orphaned — they still run on the node but have no namespace parent in the API. Always force-delete pods first:

```bash
kubectl delete pods --all -n my-namespace --force --grace-period=0
```

**6. jq may not be installed**

The force-finalize command uses `jq`. On minimal cloud images it may not be installed:

```bash
apt-get install -y jq    # Debian/Ubuntu
yum install -y jq        # Amazon Linux / RHEL
brew install jq          # macOS
```

## Key Takeaways

**Finalizers are not bugs — they are safety mechanisms.** They exist to prevent orphaned cloud resources. When they get stuck, it's because the system lost track of its own cleanup process, not because Kubernetes is broken.

**Force-finalize is surgery, not a shortcut.** It tells Kubernetes "this is done" without doing the cleanup. Use it only when:

- The owning controller no longer exists
- You have verified there are no cloud resources left to clean up, or you're prepared to clean them up manually

**On AWS EKS, the correct teardown order is:**

1. Delete workloads (Pods, Services) — while controllers are still running
2. Delete controllers (AWS LB Controller, cert-manager, etc.)
3. Force-finalize stuck namespaces if any remain
4. Run `eksctl delete cluster`
5. Verify and manually delete any orphaned NLBs, security groups, and VPCs

**The two-step failure pattern to memorize:**

- Step A: You delete the AWS Load Balancer Controller before deleting your `LoadBalancer` Services
- Step B: The NLB lives in AWS forever, blocks your VPC, and the only fix is finding it via AWS CLI and deleting it manually

**The diagnostic you should always run first:**

```bash
kubectl get namespace <name> -o json | jq '.status.conditions'
```

This tells you exactly what is blocking deletion and why. Never guess — read the status first.

---

*Written from a real AWS EKS cluster teardown: a 5-node LangGraph SRE agent project on EKS ap-south-1, where both of the above failure patterns were hit in sequence during final infrastructure teardown.*
