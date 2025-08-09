#!/usr/bin/env bash
# setup-ansible-venv.sh
# Usage: ./setup-ansible-venv.sh
# This script sets up a Python virtual environment and installs Ansible.

set -e  # Exit immediately if a command exits with a non-zero status

echo "Creating Python virtual environment in .venv..."
python3 -m venv .venv

echo "Activating virtual environment..."
source .venv/bin/activate

echo "Upgrading pip..."
pip install --upgrade pip

echo "Installing Ansible..."
pip install ansible

echo "✅ Ansible virtual environment is ready!"
echo "To activate it in the future, run: source .venv/bin/activate"
