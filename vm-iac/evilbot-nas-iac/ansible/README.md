# Ansible for evilbot-nas

This playbook backs up key parts of the Ubuntu 24.04 file server.

## Features
- Saves list of installed packages
- Archives /etc
- Archives Samba config

## Usage

1. Set correct IP in `inventory/hosts`
2. SSH access as `david` with key-based login
3. Run with:

    ansible-playbook backup-playbook.yml

