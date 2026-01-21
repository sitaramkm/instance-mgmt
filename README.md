# Instance Management – Server & Agent VMs (Multipass + EC2)

## Supported providers
  - Multipass
  - AWS
  - GCP 
  - Azure (TODO)

This repository provides simple shell scripts to create and destroy
**Ubuntu-based server and agent VMs** locally (Multipass) or in **AWS EC2**, **GCP**, **Azure**.

It supports:
- One **server** VM
- One **agent** VM
- **LLM workloads using Ollama**
- Clean teardown

---

## Configuration (`common.env`)

All defaults must be in `common.env`. Copy `common.env.example` as `common.env`

```bash

# SSH user
SSH_USER=ubuntu

# Naming
SERVER_NAME=server-01
AGENT_NAME=agent-01

# AWS
AWS_PROFILE=sitaram
AWS_REGION=us-east-2
AMI_ID=ami-04f167a56786e4b09
INSTANCE_TYPE=t3.small
AGENT_INSTANCE_TYPE_AI=g5.xlarge
DISK_GB=20

# Multipass defaults
UBUNTU_VER=24.04
VM_CPUS=2
VM_MEM=2G
VM_DISK=20G
```
---
## Examples


```bash
# Local VMs
./scripts/create-vm.sh multipass

# EC2 (standard agents)
❯ ./scripts/create-vm.sh aws
ERROR: AWS CLI is not authenticated.
Run: aws configure or aws sso login

# With AI / Ollama agents (will use a bigger VM)
./scripts/create-vm.sh aws --ai

# Access VM's
ssh -i '/full/path/.ssh/ec2_rsa' ubuntu@<server-ip>
ssh -i '/full/path/.ssh/ec2_rsa' ubuntu@<agent-ip>

./scripts/destroy-vm.sh <provider> [multipass, aws, gcp, azure]
```

## Install Ollama 

Installs Ollama on a single agent VM
What it does:
- Installs Ollama
- Enables it as a systemd service
- Pulls a default model
- Exposes API on port 11434

```bash
# Install ollama 
./scripts/install-llm.sh aws|gcp|azure

# Example
./scripts/install-llm.sh aws|gcp|azure
```

## instances.env (Generated File)
After VM creation, **[PROVIDER]-instances.env** is generated.

For e.g `mp-instances.env`, `aws-instances.env`, etc.

It contains:
- SSH key path
- SSH user
- Instance IPs
- Security groups
- Provider context

## Allowing additional IPs / CIDRS (non Multipass)
Applies to:
- SSH (22)
- Ollama (11434, agents only)
```bash
./scripts/gcp/gcp-allow.sh allow 203.0.113.5/32
./scripts/aws/ec2-allow.sh allow 10.0.0.0/16
```