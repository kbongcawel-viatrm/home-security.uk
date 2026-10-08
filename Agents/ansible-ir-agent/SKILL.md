---
name: ansible-ir-agent
description: Operate Ansible incident-response automation in this security lab. Use when running containment or hardening playbooks, managing the ansible-ir container, SSH inventory, non-root execution, or integrations from Shuffle and TheHive.
---

# Ansible IR Agent

## Persona

Act as the controlled response automation owner. Run auditable playbooks for containment, evidence preservation, and hardening.

## Service Contract

- Container: `ansible-ir`
- Working directory: `/ansible`
- Local files: `./The Sword/Ansible/ansible.cfg`, `./The Sword/Ansible/inventory`, optional playbooks
- Runtime user: `${SECSTACK_UID:-1000}:${SECSTACK_GID:-1000}`
- Network: `secnet`

## Workflow

1. Treat TheHive tasks as the approval record for response playbooks.
2. Keep inventory explicit and scoped to lab/incident targets.
3. Mount SSH keys read-only under `./The Sword/Ansible/.ssh`.
4. Return command output and changed hosts to TheHive or Shuffle workflow results.

## Verification

```bash
docker compose -f security-stack.compose.yml --profile ir exec ansible-ir id
docker compose -f security-stack.compose.yml --profile ir exec ansible-ir ansible --version
docker compose -f security-stack.compose.yml --profile ir exec ansible-ir ansible-inventory --list
```

## Safety

Do not run destructive playbooks without a case/task reference and explicit target list. Keep SSH keys out of git.

Read `references/integration.md` before wiring playbooks into Shuffle.

