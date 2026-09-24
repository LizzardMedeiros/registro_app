# shellcheck shell=bash
# Geradores das políticas IAM/S3 usadas pelos scripts. Mantidos em funções puras
# para que scripts/test/run.sh valide o conteúdo sem acesso à AWS.

# Leitura pública apenas dos objetos do site (sem listagem, sem escrita).
policy_site_bucket() {
  local bucket="$1"
  jq -n --arg b "$bucket" '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "PublicReadSiteObjects",
      Effect: "Allow",
      Principal: "*",
      Action: "s3:GetObject",
      Resource: "arn:aws:s3:::\($b)/*"
    }]
  }'
}

# Trust da role de execução do ECS.
policy_ecs_exec_trust() {
  local account="$1"
  jq -n --arg a "$account" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: { Service: "ecs-tasks.amazonaws.com" },
      Action: "sts:AssumeRole",
      Condition: { StringEquals: { "aws:SourceAccount": $a } }
    }]
  }'
}

# Leitura dos segredos do próprio ambiente no SSM (injetados no container).
policy_ecs_exec_ssm() {
  local account="$1" region="$2" env="$3"
  jq -n --arg a "$account" --arg r "$region" --arg e "$env" '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "ReadEnvSecrets",
      Effect: "Allow",
      Action: ["ssm:GetParameters"],
      Resource: "arn:aws:ssm:\($r):\($a):parameter/registro/\($e)/*"
    }]
  }'
}

# Trust da role do GitHub Actions: só o environment informado do repositório
# (subject imutável, ex.: repo:owner@123/repo@456:environment:lab).
policy_github_trust() {
  local account="$1" sub_prefix="$2" gh_env="$3"
  jq -n --arg a "$account" --arg s "${sub_prefix}:environment:${gh_env}" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: { Federated: "arn:aws:iam::\($a):oidc-provider/token.actions.githubusercontent.com" },
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {
        StringEquals: {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": $s
        }
      }
    }]
  }'
}
