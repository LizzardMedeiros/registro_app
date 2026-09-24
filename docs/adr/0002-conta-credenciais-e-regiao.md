# 0002. Conta, credenciais e região do laboratório

- Status: Aceito
- Data: 2026-09-24

## Contexto

O `DEPLOY.md` pede uma conta AWS com faturamento ativo, uma credencial IAM ou SSO
(não root) e uma cópia própria do repositório. O responsável criou uma conta
pessoal nova (270244457878) só para o workshop. A única credencial disponível é
o usuário root, via `aws login` (credenciais temporárias da sessão do console).
A conta ainda estava em ativação no início do trabalho (`OptInRequired`).

## Decisão

- Conta: 270244457878, perfil local `personal`, região `us-east-1`.
- Credencial local: root via `aws login --profile personal`. O `DEPLOY.md`
  proíbe root salvo confirmação; o responsável confirmou explicitamente seguir
  com root por ser uma conta descartável do laboratório.
- Identificador do ambiente: `lab-lizzard` (nomes `registro-lab-lizzard-*` e tag
  `Environment=lab-lizzard`).
- Repositório: fork `LizzardMedeiros/registro_app` (upstream
  `lucianoaugusto1/registro_app`), com Actions habilitado e permissão de admin.

## Consequências

- Os scripts avisam em toda execução quando a credencial é root.
- Não há chaves de acesso de longa duração na máquina: `aws login` renova a sessão.
- Risco aceito: um erro local tem alcance total na conta. Mitigação: os scripts
  validam a conta esperada antes de qualquer alteração e só tocam recursos com o
  prefixo do ambiente.
- Recomendado após o workshop: MFA no root e um usuário do IAM Identity Center
  para uso diário (com `SignInLocalDevelopmentAccess` para `aws login`).
