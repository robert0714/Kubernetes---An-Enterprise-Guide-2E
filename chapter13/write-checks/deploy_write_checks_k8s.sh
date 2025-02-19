#!/bin/bash

export hostip=$(hostname  -I | cut -f1 -d' ' | sed 's/[.]/-/g')

echo "getting the jwt"
export JWT=$(curl --insecure -u 'mmosley:start123' https://k8sou.$hostip.nip.io/k8s-api-token/token/user 2>/dev/null| jq -r '.token.id_token')

echo "getting the content of jwt"
export JWT_CONTENT=$(jq -R 'split(".") | select(length > 0) | .[1] | @base64d | fromjson' <<< $JWT)

echo "getting Jwt issuer"
export jwt_issuer=$(jq -r '.iss' <<< $JWT_CONTENT)

echo "getting openid-config"
curl --insecure  $jwt_issuer/.well-known/openid-configuration 2>/dev/null | jq -r  

echo "getting oidc config"
export oidc_config=$(curl --insecure  $jwt_issuer/.well-known/openid-configuration 2>/dev/null | jq -r '.jwks_uri')


echo "getting jwks"
export jwks=$(curl --insecure $oidc_config 2>/dev/null | jq -c '.')

sed "s/IPADDR/$hostip/g" < ./write_checks.yaml | sed "s/JWKS_FROM_SERVER/$jwks/g"   > /tmp/write_checks.yaml

kubectl apply -f /tmp/write_checks.yaml