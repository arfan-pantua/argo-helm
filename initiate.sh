#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export ACCOUNT_ID=...
export OIDC_PROVIDER=...
export SERVICE_ACCOUNT_NAME=...
export ROLE_NAME=...
export POLICY_NAME=...
export RELEASE_NAME=...
export ARGO_NAMESPACE=...
# Set to the specific version
export ARGO_VERSION=7.9.1

# AVP Plugin
export AWS_REGION=...

$ RBAC
export QA_GROUP_ID=...
export DEV_GROUP_ID=...
export ADMIN_GROUP_ID=...

# IAM SSO
export DOMAIN_NAME=...
export SSO_URL=... # IAM Identity Center sign-in URL
export CA_DATA=... # IAM Identity Center Certificate BASE64 ENCODED STRING

# Env Definition
export ARGO_VALUES=argo.values.yaml
export ARGO_CONFIGMAP_PLUGIN=avp-configmap.yaml

# Set namespace
echo "-- Set the kubectl context to use the Argo Namespace: $ARGO_NAMESPACE"
kubectl config set-context --current --namespace=$ARGO_NAMESPACE

# Create Service Account
kubectl create serviceaccount $SERVICE_ACCOUNT_NAME

###---
cat << EOF > trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${ARGO_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
        }
      }
    }
  ]
}
EOF

ROLE_ARN=$(aws iam create-role --role-name ${ROLE_NAME} \
     --assume-role-policy-document file://trust.json)

kubectl annotate serviceaccount -n ${ARGO_NAMESPACE} \
     ${SERVICE_ACCOUNT_NAME} \
         eks.amazonaws.com/role-arn=$(echo $ROLE_ARN | jq -r '.Role.Arn')
echo "-- Service Account and role were created"

# ###---
cat << EOF > policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "VisualEditor0",
            "Effect": "Allow",
            "Action": [
                "secretsmanager:*",
                "eks:*"
            ],
            "Resource": "*"
        }
    ]
}
EOF
POLICY_ARN=$(aws iam create-policy --policy-name ${POLICY_NAME} --policy-document file://policy.json)
aws iam attach-role-policy --policy-arn $(echo $POLICY_ARN | jq -r '.Policy.Arn') --role-name ${ROLE_NAME}

# Prepare the new values
cat << EOF > $ARGO_VALUES
configs:
  cmp:
    create: true
    plugins:
      argocd-vault-plugin:
        discover:
          find:
            command:
            - sh
            - -c
            - "find . -name '*.yaml' -o -name '*.yml'"
        generate:
          command:
          - argocd-vault-plugin
          - generate
          - --verbose-sensitive-output
          - .
      argocd-vault-plugin-helm:
        allowConcurrency: true
        discover:
          find:
            command:
            - sh
            - -c
            - find . -name 'Chart.yaml' && find . -name 'values.yaml'
        generate:
          command:
          - sh
          - -c
          - "argocd-vault-plugin generate all.yaml"
        init:
          command:
          - sh
          - -c
          - "helm dependency build --debug && helm template $ARGOCD_ENV_releaseName --debug --include-crds -n $ARGOCD_APP_NAMESPACE ${ARGOCD_ENV_helmArgs} . > all.yaml"

  cm:
    admin.enabled: "false"
    application.instanceLabelKey: argocd.argoproj.io/instance
    create: true
    dex.config: |
      logger:
        level: debug
        format: json
      connectors:
      - type: saml
        id: aws
        name: "AWS"
        config:
          ssoURL: $SSO_URL
          entityIssuer: https://argo.hydrax.io/api/dex/callback
          caData: |
            $CA_DATA
          redirectURI: https://argo.hydrax.io/api/dex/callback
          usernameAttr: email
          emailAttr: email
          groupsAttr: groups
    exec.enabled: "false"
    server.rbac.log.enforce.enable: "false"
    timeout.hard.reconciliation: 0s
    timeout.reconciliation: 180s
    url: https://argo.hydrax.io
  params:
    server.insecure: true
  rbac:
    create: true
    policy.csv: |
      p, role:admin, applications, *, */*, allow
      p, role:admin, clusters, *, *, allow
      p, role:admin, repositories, *, *, allow
      p, role:admin, projects, *, *, allow
      p, role:read-write, applications, *, */*, allow
      p, role:read-only, applications, get, */*, allow
      p, role:read-only, applications, sync, */*, allow
      g, b91a258c-1001-7092-a418-3dce8f0e8d37, role:read-only
      g, 96671cc538-b98d9762-e32c-4331-a123-6fd318aebec0, role:read-only
      g, a91a95ec-e011-707f-c839-777b9b67e565, role:read-write
      g, 96671cc538-cb7506d2-88fe-41e4-8562-4af30cd8e1a9, role:read-write
      g, 96671cc538-e17eebb3-56e3-4dd2-b017-e7704c5276e6, role:read-write
      g, b9aa85fc-2001-703e-1a3c-3e59a30c2945, role:admin
    policy.default: role:read-only
    scopes: '[groups, email]'
crds:
  install: true
redis:
  enabled: true
repoServer:
  replicas: 2
  extraContainers:
  - command:
    - /var/run/argocd/argocd-cmp-server
    env:
    - name: AVP_TYPE
      value: awssecretsmanager
    - name: AVP_AUTH_TYPE
      value: k8s
    - name: AWS_REGION
      value: ap-southeast-1
    image: quay.io/argoproj/argocd:v2.14.8
    name: avp
    securityContext:
      runAsNonRoot: true
      runAsUser: 999
    volumeMounts:
    - mountPath: /var/run/argocd
      name: var-files
    - mountPath: /home/argocd/cmp-server/plugins
      name: plugins
    - mountPath: /tmp
      name: cmp-tmp
    - mountPath: /home/argocd/cmp-server/config/plugin.yaml
      name: cmp-plugin
      subPath: argocd-vault-plugin.yaml
    - mountPath: /usr/local/bin/argocd-vault-plugin
      name: custom-tools
      subPath: argocd-vault-plugin
  - command:
    - /var/run/argocd/argocd-cmp-server
    env:
    - name: AVP_TYPE
      value: awssecretsmanager
    - name: AVP_AUTH_TYPE
      value: k8s
    - name: AWS_REGION
      value: ap-southeast-1
    image: quay.io/argoproj/argocd:v2.14.8
    name: avp-helm
    securityContext:
      runAsNonRoot: true
      runAsUser: 999
    volumeMounts:
    - mountPath: /var/run/argocd
      name: var-files
    - mountPath: /home/argocd/cmp-server/plugins
      name: plugins
    - mountPath: /tmp
      name: cmp-tmp
    - mountPath: /home/argocd/cmp-server/config/plugin.yaml
      name: cmp-plugin
      subPath: argocd-vault-plugin-helm.yaml
    - mountPath: /usr/local/bin/argocd-vault-plugin
      name: custom-tools
      subPath: argocd-vault-plugin
  initContainers:
  - args:
    - wget -O argocd-vault-plugin https://github.com/argoproj-labs/argocd-vault-plugin/releases/download/v1.18.1/argocd-vault-plugin_1.18.1_linux_amd64
      && chmod +x argocd-vault-plugin && mv argocd-vault-plugin /custom-tools/
    command:
    - sh
    - -c
    env:
    - name: AVP_VERSION
      value: 1.18.1
    image: alpine:3.21
    name: download-tools
    volumeMounts:
    - mountPath: /custom-tools
      name: custom-tools
  nodeSelector:
    dedicated: monitoring
  serviceAccount:
    create: false
    name: argocd-sa
  volumes:
  - configMap:
      name: argocd-cmp-cm
    name: cmp-plugin
  - emptyDir: {}
    name: custom-tools
  - emptyDir: {}
    name: cmp-tmp
server:
  serviceAccount:
    create: false
    name: argocd-sa
controller:
  serviceAccount:
    create: false
    name: argocd-sa
EOF

echo "-- Upgrade the helm: $ARGO_VERSION"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install --version $ARGO_VERSION $RELEASE_NAME argo/argo-cd --values $ARGO_VALUES