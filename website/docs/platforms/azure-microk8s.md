# Azure MicroK8s Host Documentation

:::caution Legacy `hosts-to-be-deleted/*` path — not yet migrated to UIS CLI
This platform still runs through the legacy `hosts-to-be-deleted/azure-microk8s/` scripts; it has not been migrated to the `platforms/*` + `./uis platform <verb>` CLI shape that [Rancher Desktop](./rancher-kubernetes.md) and [Azure AKS](./azure-aks.md) use. Concretely, **`./uis platform list/use/init/up/status/down` do not work for this target yet** — you'll see it omitted from the platform list output. The instructions below describe the legacy flow and may be outdated.

The migration is tracked at [INVESTIGATE-system-migrate-hosts-to-platforms.md](../ai-developer/plans/backlog/INVESTIGATE-system-migrate-hosts-to-platforms.md). For most use cases, [Azure AKS](./azure-aks.md) (managed Kubernetes) is a better target than self-managed MicroK8s on a VM.
:::
**Last Updated**: September 22, 2024

## 📋 Overview

This guide covers setting up a VM in Azure using the Cloud Adoption Framework (CAF) with MicroK8s. In a CAF environment, resources are locked down by default, requiring explicit permissions for access. While this enhances security, it adds complexity to the setup process.

### **Key Features**
- **Azure VM deployment** with automated MicroK8s installation
- **CAF compliance** with proper resource group and networking setup
- **Tailscale VPN integration** for secure remote access
- **Cloud-init automation** for consistent provisioning
- **Ansible integration** for ongoing management

## Automated Setup with Enhanced Script

We've created an improved script (`01-azure-vm-create-redcross-v2.sh`) that handles the entire deployment process, including error handling and detailed feedback.

### Prerequisites

- Azure subscription with Contributor role access
- Tailscale account and network setup
- SSH keys for the ansible user
- **Configuration setup**: Copy the template file and add your Azure credentials (see Configuration section below)

### Deployment Process

## Configuration

**IMPORTANT**: Before running any deployment scripts, you must configure your Azure credentials:

1. **Copy the template file**:
   ```bash
   cd hosts-to-be-deleted/azure-microk8s
   cp azure-vm-config-redcross-sandbox.sh-template azure-vm-config-redcross-sandbox.sh
   ```

2. **Edit the configuration file** and replace placeholder values with your actual Azure information:
   ```bash
   nano azure-vm-config-redcross-sandbox.sh
   ```

   Replace these placeholder values:
   - `TENANT_ID="your-tenant-id"` → Your Azure tenant ID
   - `SUBSCRIPTION_ID="your-subscription-id"` → Your Azure subscription ID
   - `your-email@organization.com` → Your actual email address
   - `your-cost-center` → Your organization's cost center

3. **Security Note**: The `azure-vm-config-redcross-sandbox.sh` file contains sensitive information and is automatically excluded from git commits via `.gitignore`.

### Deployment Process

The deployment uses these files:

* **VM configuration**: `azure-vm-config-redcross-sandbox.sh` (created from template above)
* **VM creation script**: `01-azure-vm-create-redcross-v2.sh`
* **Ansible inventory**: `02-azure-ansible-inventory.sh`
* **Resource cleanup**: `azure-vm-cleanup-redcross-v2.sh`

### Running the Creation Script

```bash
./01-azure-vm-create-redcross-v2.sh <admin_username> <admin_password> <vm_instance>
```

Example:
```bash
./01-azure-vm-create-redcross-v2.sh ansible <your-password> azure-microk8s
```

The script performs these steps:
1. Checks for required configuration files
2. Prompts you to activate your Privileged Identity Management (PIM) role if needed
3. Logs into Azure and sets the subscription
4. Creates resource groups for VM and networking if they don't exist
5. Sets up network components (VNet, subnet, NSG)
6. Creates and configures the VM with MicroK8s
7. Formats and mounts the data disk
8. Verifies Tailscale connectivity
9. Creates cluster information file
10. Tests SSH access through Tailscale
11. Shows MicroK8s status and provides comprehensive summary

> **Important**: The script uses cloud-init to configure the VM, including Tailscale setup. The cloud-init file should include a valid Tailscale auth key.

### Cloud-Init Configuration

The cloud-init file (`/mnt/urbalurbadisk/cloud-init/azure-cloud-init.yml`) handles initial VM setup:
- Creates the `ansible` user with SSH key access
- Installs MicroK8s with core add-ons
- Installs and configures Tailscale for secure remote access

For more information about cloud-init configuration, see `cloud-init/cloud-init-readme.md`

### Accessing the VM

After deployment, access the VM via Tailscale:

```bash
ssh -i /mnt/urbalurbadisk/secrets/id_rsa_ansible -F /dev/null ansible@<tailscale-ip>
```

Where `<tailscale-ip>` is the Tailscale IP displayed at the end of the script execution.

The provision-host (the local container or VM) must also be connected to the Tailscale network to connect over the Tailscale network. For more about Tailscale see `networking/vpn-tailscale-howto.md`

### Deleting the VM

To remove the VM and associated resources, use the improved cleanup script:

```bash
./azure-vm-cleanup-redcross-v2.sh <vm_instance>
```

Example:
```bash
./azure-vm-cleanup-redcross-v2.sh azure-microk8s
```

The cleanup script will:
1. Prompt you to activate your PIM role if needed
2. Log into Azure and set the subscription
3. List all resources that will be deleted and ask for confirmation
4. If the VM is the only one in its resource group, offer to delete the entire group (faster)
5. Remove all associated resources (VM, disks, NIC, NSG)
6. Optionally wait to verify that the resource group has been fully deleted
7. Remind you to manually delete the machine from your Tailscale network

## Manual Installation (For Troubleshooting)

If you need to troubleshoot or understand the underlying process, here are the manual steps:

### Step 1: Set Up the Azure Environment

1. Create resource groups:
```bash
az group create --name rg-sandbox-k8s-weu --location westeurope
az group create --name rg-sandbox-network-weu --location westeurope
```

2. Create networking components:
```bash
az network vnet create --resource-group rg-sandbox-network-weu --name vnet-sandbox-network-weu --address-prefix 10.2.0.0/16 --location westeurope
az network vnet subnet create --resource-group rg-sandbox-network-weu --vnet-name vnet-sandbox-network-weu --name sub-sandbox-k8s-weu --address-prefix 10.2.1.0/24
az network nsg create --resource-group rg-sandbox-k8s-weu --name nsg-sandbox-k8s-azure-microk8s-weu --location westeurope
```

3. Create network interface:
```bash
az network nic create --resource-group rg-sandbox-k8s-weu --name nic-sandbox-k8s-azure-microk8s-weu --subnet /subscriptions/<subscription-id>/resourceGroups/rg-sandbox-network-weu/providers/Microsoft.Network/virtualNetworks/vnet-sandbox-network-weu/subnets/sub-sandbox-k8s-weu --network-security-group nsg-sandbox-k8s-azure-microk8s-weu
```

4. Create VM with cloud-init:
```bash
az vm create --resource-group rg-sandbox-k8s-weu --name vm-sandbox-k8s-azure-microk8s-weu --image Ubuntu2204 --size Standard_B2ms --location westeurope --admin-username "ansible" --admin-password "<your-password>" --authentication-type password --storage-sku Standard_LRS --data-disk-sizes-gb 50 --nics nic-sandbox-k8s-azure-microk8s-weu --custom-data @/mnt/urbalurbadisk/cloud-init/azure-cloud-init.yml
```

### Step 2: Verify Tailscale Connectivity

1. Check if Tailscale is running on the VM:
```bash
az vm run-command invoke --resource-group rg-sandbox-k8s-weu --name vm-sandbox-k8s-azure-microk8s-weu --command-id RunShellScript --scripts "tailscale status"
```

2. Get the Tailscale IP:
```bash
az vm run-command invoke --resource-group rg-sandbox-k8s-weu --name vm-sandbox-k8s-azure-microk8s-weu --command-id RunShellScript --scripts "tailscale ip -4"
```

3. Test SSH access:
```bash
ssh -i /mnt/urbalurbadisk/secrets/id_rsa_ansible -F /dev/null ansible@<tailscale-ip>
```

### Step 3: Format and Mount Data Disk

```bash
az vm run-command invoke --resource-group rg-sandbox-k8s-weu --name vm-sandbox-k8s-azure-microk8s-weu --command-id RunShellScript --scripts "sudo parted /dev/sdc --script mklabel gpt mkpart xfspart xfs 0% 100% && sudo mkfs.xfs /dev/sdc1 && sudo partprobe /dev/sdc1 && sudo mkdir -p /mnt/urbalurbadisk && sudo mount /dev/sdc1 /mnt/urbalurbadisk && echo '/dev/sdc1 /mnt/urbalurbadisk xfs defaults 0 2' | sudo tee -a /etc/fstab && sudo chown ansible:ansible /mnt/urbalurbadisk && sudo chmod 755 /mnt/urbalurbadisk"
```

### Step 4: Verify MicroK8s Installation

```bash
az vm run-command invoke --resource-group rg-sandbox-k8s-weu --name vm-sandbox-k8s-azure-microk8s-weu --command-id RunShellScript --scripts "microk8s status"
```

## Troubleshooting

### Cloud-Init Issues
If cloud-init fails, check the logs:
```bash
az vm run-command invoke --resource-group rg-sandbox-k8s-weu --name vm-sandbox-k8s-azure-microk8s-weu --command-id RunShellScript --scripts "cat /var/log/cloud-init-output.log | tail -n 50"
```

### Tailscale Connectivity
If Tailscale isn't connecting:
1. Verify Tailscale installation:
```bash
az vm run-command invoke --resource-group rg-sandbox-k8s-weu --name vm-sandbox-k8s-azure-microk8s-weu --command-id RunShellScript --scripts "which tailscale && systemctl status tailscaled"
```

2. Check for valid auth keys in your cloud-init file and create a new auth key if needed from the Tailscale admin console.

### SSH Access Problems
If SSH access fails:
1. Verify the SSH key path: `/mnt/urbalurbadisk/secrets/id_rsa_ansible`
2. Check SSH key permissions: `chmod 600 /mnt/urbalurbadisk/secrets/id_rsa_ansible`
3. Bypass SSH config with the `-F /dev/null` option

## Sample Output Logs

### Create VM Example Log

Below is a truncated example of a successful VM creation:


```plaintext
./01-azure-vm-create-redcross-v2.sh ansible Secretp@ssword1 azure-microk8s
================================================
    Azure VM Creation Script v2 (Full Setup)    
================================================
Starting Azure VM creation process for instance: azure-microk8s

=== STEP 1: Checking required files and loading configuration ===
  → Checking if ./azure-vm-config-redcross-sandbox.sh exists
  ✓ File ./azure-vm-config-redcross-sandbox.sh found
  → Checking if /mnt/urbalurbadisk/cloud-init/azure-cloud-init.yml exists
  ✓ File /mnt/urbalurbadisk/cloud-init/azure-cloud-init.yml found
  → Loading configuration from ./azure-vm-config-redcross-sandbox.sh
  ✓ Configuration loaded
  → Generating resource names
Configured variables:
  VM Instance Name: vm-sandbox-k8s-azure-microk8s-weu
  VM Resource Group: rg-sandbox-k8s-weu
  Network Resource Group: rg-sandbox-network-weu
  Subscription ID: <your-subscription-id>

=== STEP 1.5: Activating Privileged Identity Management (PIM) role ===
IMPORTANT: You need the Contributor role on the Azure subscription to run this script.
In Azure this is a ClickOps operation (the M$ guys did not grow up using a command line tool)
To activate the Contributor role in Azure:
  1) Search for PIM in the Azure portal search bar
  2) Click on Microsoft Entra Privileged Identity Management
  3) On the PIM page, click "My roles"
  4) Click "Azure resources"
  5) Click "Activate" next to the Contributor role

Alternatively, click on this URL (Ctrl+Click in most terminals):
https://portal.azure.com/?feature.msaljs=true#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac
Search for your resource, click on the name, and then click on the Contributor role.

After you have activated your Contributor role, press Enter to continue...
Continuing with script execution...

=== STEP 2: Setting up Azure CLI and login ===
  → Running: Setting login experience
  ✓ Azure CLI: Setting login experience
  → Initiating Azure login
Please follow these steps to log in:
  1. Open a web browser and go to: https://microsoft.com/devicelogin
  2. Enter the code that will be displayed below
  3. Follow the prompts to complete the login process
Running: az login --tenant <your-tenant-id> --use-device-code
To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code XXXXXXXX to authenticate.
[
  {
    "cloudName": "AzureCloud",
    "homeTenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "isDefault": true,
    "managedByTenants": [],
    "name": "Your Subscription Name",
    "state": "Enabled",
    "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "user": {
      "name": "user@organization.com",
      "type": "user"
    }
  }
  // Additional subscriptions may appear here
]
  ✓ Azure login successful
  → Running: Set subscription
  ✓ Azure: Set subscription

=== STEP 3: Checking for existing resources ===
  → Checking if VM already exists: vm-sandbox-k8s-azure-microk8s-weu
  ✓ VM does not exist, can proceed with creation

=== STEP 4: Creating Resource Groups ===
  → Checking if Resource Group rg-sandbox-k8s-weu exists
  → Creating Resource Group: rg-sandbox-k8s-weu in westeurope
  → Running: Create rg-sandbox-k8s-weu
  ✓ Resource Group: Create rg-sandbox-k8s-weu
  → Checking if Resource Group rg-sandbox-network-weu exists
  → Creating Resource Group: rg-sandbox-network-weu in westeurope
  → Running: Create rg-sandbox-network-weu
  ✓ Resource Group: Create rg-sandbox-network-weu

=== STEP 5: Creating VNet and Subnet ===
  → Checking if VNet vnet-sandbox-network-weu exists
  ✓ VNet vnet-sandbox-network-weu already exists
  → Checking if Subnet sub-sandbox-k8s-weu exists
/subscriptions/<subscription-id>/resourceGroups/rg-sandbox-network-weu/providers/Microsoft.Network/virtualNetworks/vnet-sandbox-network-weu/subnets/sub-sandbox-k8s-weu
  ✓ Subnet sub-sandbox-k8s-weu already exists
  → Updating SUBNET_FULL_PATH variable

=== STEP 6: Creating Network Security Group ===
  → Checking if NSG nsg-sandbox-k8s-azure-microk8s-weu exists
  → Creating NSG: nsg-sandbox-k8s-azure-microk8s-weu
  → Running: Create NSG
  ✓ Network: Create NSG
  → Using Tailscale for secure access - no external SSH rule needed

=== STEP 7: Creating Network Interface ===
  → Creating network interface: nic-sandbox-k8s-azure-microk8s-weu
  → Running: Create interface
  ✓ Network: Create interface

=== STEP 8: Creating Virtual Machine with Data Disk ===
  → Starting VM creation (this may take several minutes)
  → Running: Create
  ✓ VM: Create

=== STEP 9: Waiting for VM to be fully provisioned ===
  → Running: Wait for creation
  ✓ VM: Wait for creation

=== STEP 10: Waiting for cloud-init to complete ===
  → Checking if cloud-init has completed processing
  → Unable to confirm cloud-init completion, checking MicroK8s status
  ✓ MicroK8s is running - cloud-init has likely completed successfully

=== STEP 11: Formatting and mounting data disk ===
  → Running on VM: Formatting and mounting data disk
  ✓ VM Command: Formatting and mounting data disk
Enable succeeded: 
[stdout]
meta-data=/dev/sdc1              isize=512    agcount=4, agsize=3276672 blks
         =                       sectsz=4096  attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=0 inobtcount=0
data     =                       bsize=4096   blocks=13106688, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=6399, version=2
         =                       sectsz=4096  sunit=1 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
Discarding blocks...Done.
/dev/sdc1 /mnt/urbalurbadisk xfs defaults 0 2
Disk formatted, mounted, and permissions set

[stderr]

=== STEP 12: Getting Tailscale IP and Hostname ===
  → Getting Tailscale IP (may take multiple attempts)
  → Attempt 1 of 10 to get Tailscale IP
  → Attempt failed. Waiting for 30 seconds before retrying...
  → Attempt 2 of 10 to get Tailscale IP
  ✓ Successfully retrieved Tailscale IP: 100.64.192.33
  → Using instance name as Tailscale hostname: azure-microk8s

=== STEP 13: Creating cluster information file ===
  → Creating: azure-microk8s.sh
  ✓ Created azure-microk8s.sh

=== STEP 14: Setting execute permissions for info file ===
  ✓ Set executable permissions

=== STEP 15: Testing Ansible user SSH access ===
  → Testing SSH connection to 100.64.192.33
Warning: Permanently added '100.64.192.33' (ED25519) to the list of known hosts.
Ansible user SSH test successful
  ✓ Ansible SSH access successful

=== STEP 16: Displaying cluster information ===
  → Checking MicroK8s status
  ✓ MicroK8s is running
Enabled addons:
  ✓ dashboard # (core) The Kubernetes dashboard
  ✓ dns # (core) CoreDNS
  ✓ ha-cluster # (core) Configure high availability on the current node
  ✓ helm # (core) Helm - the package manager for Kubernetes
  ✓ helm3 # (core) Helm 3 - the package manager for Kubernetes
  ✓ hostpath-storage # (core) Storage class; allocates storage from host directory
  ✓ metrics-server # (core) K8s Metrics Server for API access to service metrics
  ✓ storage # (core) Alias to hostpath-storage add-on, deprecated

===== Azure VM Creation Summary =====
Component Status:
  Network - Update variables: OK
  Cloud-Init - Completion: Likely successful (MicroK8s running)
  Resource Group - Create rg-sandbox-k8s-weu: OK
  Network - Create NSG: OK
  Network - Create interface: OK
  Ansible - SSH Test: Successful
  Resource Group - Create rg-sandbox-network-weu: OK
  VM Command - Formatting and mounting data disk: OK
  Azure - Set subscription: OK
  VM - Create: OK
  Tailscale - Hostname: azure-microk8s
  VM - Wait for creation: OK
  Configuration - File Permissions: Set successfully
  MicroK8s - Status: Running
  Network - SSH Access: Secured via Tailscale
  Azure CLI - Setting login experience: OK
  Tailscale - IP: 100.64.192.33

VM creation completed successfully.
  Virtual Machine: vm-sandbox-k8s-azure-microk8s-weu
  Resource Group: rg-sandbox-k8s-weu
  Tailscale IP: 100.64.192.33
  Tailscale Hostname: azure-microk8s

To SSH to the VM, use:
  ssh -i /mnt/urbalurbadisk/secrets/id_rsa_ansible ansible@100.64.192.33
```  

### Inventory log

```plaintext
./02-azure-ansible-inventory-v2.sh
================================================
      Azure VM Ansible Inventory Update V2      
================================================

=== STEP 1: Checking current directory ===
  → Current directory: azure-microk8s
  ✓ Correct directory confirmed: hosts-to-be-deleted/azure-microk8s

=== STEP 2: Loading configuration ===
  → Checking if ./azure-vm-config-redcross-sandbox.sh exists
  ✓ File ./azure-vm-config-redcross-sandbox.sh found
  → Loading configuration from ./azure-vm-config-redcross-sandbox.sh
  ✓ Successfully loaded configuration from ./azure-vm-config-redcross-sandbox.sh
  → Checking if azure-microk8s.sh exists
  ✓ File azure-microk8s.sh found
  → Loading cluster information from azure-microk8s.sh
  ✓ Successfully loaded cluster information from azure-microk8s.sh
  → Loaded configuration:
  Cluster Name: azure-microk8s
  Tailscale IP: 100.64.192.33
  Host Name: vm-sandbox-k8s-azure-microk8s-weu
  Ansible Directory: /mnt/urbalurbadisk/ansible

=== STEP 3: Updating Ansible inventory ===
  → Validating configuration variables
  ✓ Configuration variables validated
  → Checking if Ansible directory exists: /mnt/urbalurbadisk/ansible
  ✓ Ansible directory exists
  → Checking if inventory playbook exists: /mnt/urbalurbadisk/ansible/playbooks/02-update-ansible-inventory.yml
  ✓ Inventory playbook exists
  → Pre-checking SSH connectivity to 100.64.192.33 (port 22)
  → Running: SSH Connectivity Test
  ✓ Network: SSH Connectivity Test
  ✓ SSH connectivity to 100.64.192.33 confirmed
  → Running Ansible playbook to update inventory
  → Running: Update Inventory
  ✓ Ansible: Update Inventory
  ✓ Ansible inventory updated successfully via playbook

=== STEP 5: Validating Ansible inventory file ===
  → Checking if inventory file exists: /mnt/urbalurbadisk/ansible/inventory.yml
  ✓ Inventory file exists
  → Checking if inventory file is valid YAML
  → Running: YAML Syntax
  ✓ Validation: YAML Syntax
  ✓ Inventory file is valid YAML
  → Checking if azure-microk8s exists in inventory
  ✓ Cluster name azure-microk8s found in inventory
  → Checking if IP address is correct
  ✓ IP address 100.x.x.x correctly set for azure-microk8s

=== STEP 4: Testing Ansible connection ===
  → Checking network connectivity to 100.x.x.x
  → Running: ICMP Ping Test
  ✓ Network: ICMP Ping Test
  ✓ Host 100.x.x.x is reachable via ICMP ping
  → Checking if SSH key exists: /mnt/urbalurbadisk/secrets/id_rsa_ansible
  ✓ SSH key found
  → Pinging host azure-microk8s via Ansible
  → Running: Connection Test
  ✓ Ansible: Connection Test
  ✓ Successfully connected to azure-microk8s via Ansible

=== STEP 6: Summary ===
===== Ansible Inventory Update Summary =====
Component Status:
  Configuration - Cluster Info: OK
  Ansible - Connection Test: OK
  Ansible - Update Inventory: OK
  Network - SSH Connectivity: OK
  Configuration - Main Config: OK
  Ansible - Inventory Update: Successful
  Environment - Directory: OK
  Network - ICMP Ping: OK
  Network - SSH Connectivity Test: OK
  Validation - YAML Syntax: OK
  Network - ICMP Ping Test: OK
  Validation - IP Address: Correct

✅ Ansible inventory update completed successfully.
  Cluster Name: azure-microk8s
  Host IP: 100.x.x.x
  Inventory File: /mnt/urbalurbadisk/ansible/inventory.yml

You can now manage this VM through Ansible:
  ansible azure-microk8s -m ping
  ansible-playbook your-playbook.yml -l azure-microk8s

Common Ansible commands:
  # Check system facts
  ansible azure-microk8s -m setup
  # Run ad-hoc command
  ansible azure-microk8s -a "microk8s status"
  # Apply a playbook to this host
  ansible-playbook path/to/playbook.yml -l azure-microk8s
```


### Cleanup Example Log

Below is a truncated example of a successful cleanup operation:

```plaintext
./azure-vm-cleanup-redcross-v2.sh azure-microk8s
→ Loading configuration from ./azure-vm-config-redcross-sandbox.sh
✓ Configuration loaded
The following resources will be deleted:
  VM Instance Name: vm-sandbox-k8s-azure-microk8s-weu
  Resource Group: rg-sandbox-k8s-weu
  Network Interface: nic-sandbox-k8s-azure-microk8s-weu
  Network Security Group: nsg-sandbox-k8s-azure-microk8s-weu
  OS Disk: disk-os-sandbox-k8s-azure-microk8s-weu
  Data Disk: disk-data-sandbox-k8s-azure-microk8s-weu

Are you sure you want to delete these resources? (yes/no): yes

=== STEP 1: Activating Privileged Identity Management (PIM) role ===
IMPORTANT: You need the Contributor role on the Azure subscription to run this script.
In Azure this is a ClickOps operation (the M$ guys did not grow up using a command line tool)
To activate the Contributor role in Azure:
  1) Search for PIM in the Azure portal search bar
  2) Click on Microsoft Entra Privileged Identity Management
  3) On the PIM page, click "My roles"
  4) Click "Azure resources"
  5) Click "Activate" next to the Contributor role

Alternatively, click on this URL (Ctrl+Click in most terminals):
https://portal.azure.com/?feature.msaljs=true#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac
Search for your resource, click on the name, and then click on the Contributor role.

After you have activated your Contributor role, press Enter to continue...
Continuing with script execution...

=== STEP 2: Setting up Azure CLI and login ===
→ Setting Azure CLI login experience
Command group 'config' is experimental and under development. Reference and support levels: https://aka.ms/CLI_refstatus
✓ Setting Azure CLI login experience succeeded
→ Initiating Azure login with device code authentication
Please follow these steps to log in:
  1. Open a web browser and go to: https://microsoft.com/devicelogin
  2. Enter the code that will be displayed below
  3. Follow the prompts to complete the login process
To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code XXXXXXXX to authenticate.
[
  // Azure subscription output - multiple subscriptions may appear
  {
    "cloudName": "AzureCloud",
    "homeTenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "isDefault": true,
    "managedByTenants": [],
    "name": "Your Subscription Name",
    "state": "Enabled",
    "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "user": {
      "name": "user@organization.com",
      "type": "user"
    }
  }
  // Additional subscriptions removed for brevity
]
✓ Azure login successful
→ Setting Azure subscription to <your-subscription-id>
✓ Setting Azure subscription succeeded

=== STEP 3: Checking for resource existence ===
→ Checking if VM exists: vm-sandbox-k8s-azure-microk8s-weu
✓ VM vm-sandbox-k8s-azure-microk8s-weu found - will be deleted

=== STEP 4: Deleting Azure resources ===
→ Checking if we should delete resource group rg-sandbox-k8s-weu
→ Only one VM exists in resource group rg-sandbox-k8s-weu - safe to delete entire group
→ Deleting entire resource group: rg-sandbox-k8s-weu
✓ Deleting resource group rg-sandbox-k8s-weu succeeded
Resource deletion initiated.
Note: Resource group deletion happens asynchronously and may take several minutes to complete.

Would you like this script to wait and confirm complete deletion? (yes/no): yes
→ Waiting for resource group deletion to complete (this may take 5-10 minutes)...
→ Attempt 1/20: Resource group is in state: Deleting. Waiting 30s...
→ Attempt 2/20: Resource group is in state: Deleting. Waiting 30s...
→ Attempt 3/20: Resource group is in state: Deleting. Waiting 30s...
→ Attempt 4/20: Resource group is in state: Deleting. Waiting 30s...
→ Attempt 5/20: Resource group is in state: Deleting. Waiting 30s...
→ Attempt 6/20: Resource group is in state: Deleting. Waiting 30s...
✓ Resource group rg-sandbox-k8s-weu has been successfully deleted!

=== STEP 5: Cleanup complete ===
Azure resources cleanup completed!
Don't forget to manually delete the host from tailscale network if needed.
Go to https://login.tailscale.com/admin/machines and delete the machine named: azure-microk8s
```
