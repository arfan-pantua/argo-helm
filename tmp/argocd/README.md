## Argo CD
Argo CD is a declarative, GitOps continuous delivery tool for Kubernetes.

### Quick Start
```
git clone https://github.com/arfan-pantua/argo-helm.git
# Fill first the value that needed to fill
# then running `argo-initiate.sh`
bash argo-initiate.sh
```

### Service Account
In this argo cd we are using service account to each pod, like argocd-reposerver or argo-server, that want to access services in AWS account. The services are, like, secret manager, S3, EKS etc.

### Sign in with AWS SSO
In Argo cd there is no usermanagement module, then argo cd doesn't provide interface to register user. So, in this repo we need to set up AWS SSO in IAM Identity Center by user or group.

### Plugin
In some case, we need to use credential in manifest, we supposed to restrict for this one. We used to still put credential one in Secret Manager AWS and access it with Argocd Vault Plugin(AVP)

### RBAC
Add some policy to user, then not every one has equal access.