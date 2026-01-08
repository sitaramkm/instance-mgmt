# Instance Management – Server & Agent VMs (Multipass + EC2)

## Supported providers
  - Multipass
  - AWS
  - GCP (TODO)
  - Azure (TODO)

This repository provides simple, readable shell scripts to create and destroy
**Ubuntu-based server and agent VMs** locally (Multipass) or in **AWS EC2**.

It supports:
- One **server** VM
- One or more **agent** VMs
- **LLM workloads using Ollama**
- Clean teardown

---

## Configuration (`common.env`)

All defaults are in `common.env`.

```bash
# Number of agent VMs
NUM_AGENTS=1

# SSH user
SSH_USER=ubuntu

# Naming
SERVER_NAME=server-01
AGENT_NAME_PREFIX=agent

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
./create-vm.sh multipass

# EC2 (standard agents)
./create-vm.sh aws

# With AI / Ollama agents (will use a bigger VM)
./create-vm.sh aws --ai

# Access VM's
ssh -i '/full/path/.ssh/ec2_rsa' ubuntu@<server-ip>
ssh -i '/full/path/.ssh/ec2_rsa' ubuntu@<agent-ip>

./destroy-vm.sh <provider> [multipass, aws]
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
./install-ollama.sh <agent-public-ip>

# Example
./install-ollama.sh 3.145.xxx.xxx
```

## instances.env (Generated File)
After VM creation, instances.env is generated.

It contains:
- SSH key path
- SSH user
- Instance IPs

## Allowing additional IPs / CIDRS 
Applies to:
- SSH (22)
- Ollama (11434, agents only)
```bash
./scripts/aws/ec2-allow.sh allow 203.0.113.5/32
./scripts/aws/ec2-allow.sh allow 10.0.0.0/16
```