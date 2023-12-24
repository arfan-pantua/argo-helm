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
export ARGO_VERSION=5.9.0

# AVP Plugin
export AWS_REGION=...

# IAM SSO
export DOMAIN_NAME=...
export SSO_URL=...
export CA_DATA=...

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


# Prepare configmap plugin
cat << EOF > $ARGO_CONFIGMAP_PLUGIN
apiVersion: v1
kind: ConfigMap
metadata:
  name: cmp-plugin
data:
  avp-kustomize.yaml: |
    ---
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: argocd-vault-plugin-kustomize
    spec:
      allowConcurrency: true

      # Note: this command is run _before_ anything is done, therefore the logic is to check
      # if this looks like a Kustomize bundle
      discover:
        find:
          command:
            - find
            - "."
            - -name
            - kustomization.yaml
      generate:
        command:
          - sh
          - "-c"
          - "kustomize build . | argocd-vault-plugin generate -"
      lockRepo: false

  avp.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: argocd-vault-plugin
    spec:
      allowConcurrency: true
      discover:
        find:
          command:
          - sh
          - -c
          - find . -name '*.yaml' | xargs -I {} grep "<path\|avp\.kubernetes\.io" {} | grep
            .
      generate:
        command:
        - argocd-vault-plugin
        - generate
        - --verbose-sensitive-output
        - .
      lockRepo: false
EOF

kubectl apply -f $ARGO_CONFIGMAP_PLUGIN
# Prepare the new values
cat << EOF > $ARGO_VALUES
configs:
  params:
    server.insecure: true
  cm:
    # -- Create the argocd-cm configmap for [declarative setup]
    create: true
    admin.enabled: 'false'

    # -- Argo CD's externally facing base URL (optional). Required when configuring SSO
    url: "https://$DOMAIN_NAME"

    dex.config: |  
      logger:
        level: debug
        format: json
      connectors:
      - type: saml
        id: aws
        name: "AWS SSO"
        config:
          ssoURL: https://portal.sso.ap-southeast-1.amazonaws.com/saml/assertion/OTQ0MTMxMDI5MDE0X2lucy01ZmM2MmU3NTM0NmZjZWI4
          caData: |
            LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURCakNDQWU2Z0F3SUJBZ0lFRDg2RVdUQU5CZ2txaGtpRzl3MEJBUXNGQURCRk1SWXdGQVlEVlFRRERBMWgKYldGNmIyNWhkM011WTI5dE1RMHdDd1lEVlFRTERBUkpSRUZUTVE4d0RRWURWUVFLREFaQmJXRjZiMjR4Q3pBSgpCZ05WQkFZVEFsVlRNQjRYRFRJek1USXhOakExTURjeU1Gb1hEVEk0TVRJeE5qQTFNRGN5TUZvd1JURVdNQlFHCkExVUVBd3dOWVcxaGVtOXVZWGR6TG1OdmJURU5NQXNHQTFVRUN3d0VTVVJCVXpFUE1BMEdBMVVFQ2d3R1FXMWgKZW05dU1Rc3dDUVlEVlFRR0V3SlZVekNDQVNJd0RRWUpLb1pJaHZjTkFRRUJCUUFEZ2dFUEFEQ0NBUW9DZ2dFQgpBTHdHSlVmRWtNSVlQQWRDQ0R3ZWFyWEYzMi9qZmRKdkZ3OXVMS2l3Z0lESUZLYkRzaGhvUDRqTEQwWllIUElVCjZ4L2x2KzV5UTdBMWF4VGU5WTVnK3hjcTNTT0p1bzl3dzRkb0k0eml3UUxTNDZ2Wm9jTlVRanNSK0hUOW5EQjgKK0VJb3paeSt6VTBKclJPUTVYazlTUWJVdnZqb0F5RGtmcTd4UjdZSDIyeENwVmR4UWNna1Awako0UFRsSmJ4TwpIUEdUZ1hxdGpBRW9jQVhnNEh6Q2VPWjVNRWtsNHpValJDUG10N0t3dHFNQWtsR3AzeWNFeWh5aTlDUll4elhrClg0cFkyZlBHZEFIOFBEZG9zZXNyTG8wT0dNd3cyL094QjZBYXNEck1XWWJqMVZ1Wnhha2NHUWp3TDV2d0hwOGMKRDZqRkQ1YmRvT2JsTTJ5L2M0a1BhTFVDQXdFQUFUQU5CZ2txaGtpRzl3MEJBUXNGQUFPQ0FRRUFSVWpDWTVCRAprREU1eXNkSCtJSTNSK1RKZGhQUkRkRXRZMXBwUmg0OGRWT3RqOG1EQkVhbjRmdElhOTBUdnpCdWJCS0plM3AvCklrb0c1QTB6dzZiQTVkaG5STzE0bXlzZFVUUktnaVZ5RTh2c2swWnFlMTZrcFd1dFFxQ2FmemhXaWsxa0dBZ1gKMzA0djFhUFBtWmI4Y0NiQURWa3FhNUJhY2o2OC9HRTdtRmFvR3pFREhrd3JJcVcxVmNBb2RVK0lCUUtPcFgxSgo5WVNESUZZNGlsdzZVQzdlNFpLaEd2WTFvMzFuOTZtRnVoaUE4RkFLRmhUdUkrK1BOb1B5ZFIwa1pSNVhRNk8yCnk4eUQvbHg1L1hQZkp3MVhKVjFmNkthVC95bWZiR1dEQ0tTTHNKRGREMHhUTk1SK0lJampiUEpNLytJT1JwT1MKNWZIL2VuSk4yejJEcEE9PQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0t
          redirectURI: https://$DOMAIN_NAME/api/dex/callback
          entityIssuer: https://$DOMAIN_NAME/api/dex/callback
          usernameAttr: email
          emailAttr: email
          groupsAttr: groups
crds:
  install: true
server:
  service:
    type: NodePort
  serviceAccount:
    create: false
    name: $SERVICE_ACCOUNT_NAME
repoServer:
  # automountServiceAccountToken: true
  extraContainers:
  - command:
    - /var/run/argocd/argocd-cmp-server
    image: quay.io/argoproj/argocd:v2.7.9
    env:
    - name: AVP_TYPE
      value: awssecretsmanager
    - name: AVP_AUTH_TYPE
      value: k8s
    - name: AWS_REGION
      value: $AWS_REGION
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
      name: tmp
    - mountPath: /home/argocd/cmp-server/config/plugin.yaml
      name: cmp-plugin
      subPath: avp.yaml
    - mountPath: /usr/local/bin/argocd-vault-plugin
      name: custom-tools
      subPath: argocd-vault-plugin
  initContainers:
  - args:
    - wget -O argocd-vault-plugin https://github.com/argoproj-labs/argocd-vault-plugin/releases/download/v1.16.1/argocd-vault-plugin_1.16.1_linux_amd64
      && chmod +x argocd-vault-plugin && mv argocd-vault-plugin /custom-tools/
    command:
    - sh
    - -c
    env:
    - name: AVP_VERSION
      value: 1.16.1
    image: alpine:3.8
    name: download-tools
    volumeMounts:
    - mountPath: /custom-tools
      name: custom-tools
  serviceAccount:
    create: false
    name: argocd-sa
  volumes:
  - configMap:
      name: cmp-plugin
    name: cmp-plugin
  - emptyDir: {}
    name: custom-tools
EOF


echo "-- Upgrade the helm: $ARGO_VERSION"
helm repo update
helm upgrade --install --version $ARGO_VERSION $RELEASE_NAME argo/argo-cd --values $ARGO_VALUES