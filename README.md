# Arch Linux on Azure

In the words of Adam Savage this will be a document of "what happened" and not a guide for "how to".

> Note: The `archlinux-2021.07.01-x86_64` release was used.

## Goals

- Start with the official arch linux installation media.

- Finish with a generalized, cloud-init enabled Azure VM Image that can be used to deploy subsequent arch linux VMs.

## Constraints

- Use Azure for as much of the image engineering work as possible.

- When using tools locally, only use well known tools.

- Install only needed packages into the new image to achieve the above goals.

# Where to start?

The official arch linux installation media supports headless installations through cloud-init. This is great as it is likely that we can leverage this to boot the installation media directly in an Azure VM. 

To test our theory we will need to first convert the installation media itself into an Azure Image.

## Convert installation ISO to VHD

Setup a working directory.

```
mkdir ~/arch-image && cd ~/arch-image
```

Install `qemu-utils` locally.

```
apt-get install qemu-utils
```

Create `convert-to-vhd.sh` script (get the script from [src/convert-to-vhd.sh](src/convert-to-vhd.sh)).

```
touch ./convert-to-vhd.sh && chmod +x ./convert-to-vhd.sh
```

Download the installation media.

``` 
wget https://syd.mirror.rackspace.com/archlinux/iso/2021.07.01/archlinux-2021.07.01-x86_64.iso
```

Run the script.

```
./convert-to-vhd.sh
```

## Upload the installation VHD to Azure

Create a new storage account.

```
<use the azure portal>
```

Upload the VHD to a new blob container.

```
<use the azure portal>
```

Create a new Image resource and select the uploaded vhd as the source.

```
<use the azure portal>
```

Create a new VM resource (which we will now call the iso VM) from the Image.

```
<use the azure portal>
```

> Note: While creating the VM add an additional data disk which we will use to install arch onto (8GB minimum).

## Does it work?

Looking at the boot diagnostics we can see that cloud-init from the installation media kicked in and provisioned the iso VM without errors.

Use bastion to SSH to the iso VM to establish if we can proceed to installation.

# Arch linux installation

After successfully booting an Azure VM from the installation media in we can follow the arch [installation guide](https://wiki.archlinux.org/title/Installation_guide) to configure the previously attached blank disk. 

Start by impersonating root as the installation media expects.

```
sudo su
```

> Note: ICMP ping won't always work in Azure so don't be alarmed by this.

## Swap

Don't create a swap partition cloud-init will do that for us later.

## Mirrors

The mirrors used are in [src/mirrorlist](src/mirrorlist). Your own list can be generated interactively using https://archlinux.org/mirrorlist/.
## Packages

Follow the official installation guide until the `pacstrap` command, then run the following instead.

```
pacstrap /mnt base linux grub openssh sudo cloud-init cloud-guest-utils gdisk inetutils git base-devel nano
```

Description of packages.

Name | Usage 
---|---
base                | The base arch package from the installation guide.
linux               | The linux kernel.
grub                | A bootloader with good documentation for Azure.
sudo                | Azure expects that this will be installed.
cloud-init          | Cloud-init package.
cloud-guest-utils   | Needed to use growpart.
gdisk               | Needed to use growpart.
inetutils           | Needed to use hostname.
git                 | Used to source AUR packages (specifically walinuxagent).
base-devel          | Used to build AUR packages (specifically walinuxagent).
nano                | User friendly text editor. 

> TODO: Raise bug for missing package dependency. The cloud-init package uses the 'hostname' binary which is not provided in any of its current dependencies. The 'inetutils' package provides the 'hostname' binary.

> TODO: Raise bug for missing package dependency. The cloud-guest-utile package uses the 'sgdisk' binary which is not provided in any of its current dependencies. The 'gdisk' package provides the 'sgdisk' binary.

## Configure

Continue with the installation guide and before exiting the chroot environment complete the following additional configuration.

**grub** 

Install grub, this command assumes we are using a Gen 1 (BIOS) VM in Azure and partitioned the disk using MBR.

```
grub-install /dev/sdc
```

Update the configuration settings file.

```
nano /etc/default/grub
```

```
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 console=ttyS0,9600

GRUB_TERMINAL_INPUT=serial 

GRUB_TERMINAL_OUTPUT=serial 

GRUB_SERIAL_COMMAND="serial --speed=9600 --unit=0 --word=8 --parity=no --stop=1"
```

Generate the configuration file.

```
grub-mkconfig -o /boot/grub/grub.cfg
```

**sudo**

Uncomment the wheel group in the sudoers config.

```
nano /etc/sudoers
```

```
%wheel ALL=(ALL) NOPASSWD: ALL
```

**network**

Configure networking through systemd-networkd.

```
rm /usr/lib/systemd/network/* 
```

```
cat << EOF > /etc/systemd/network/eth0.network
[Match]
Name=eth0

[Network]
DHCP=ipv4
LinkLocalAddressing=no

[DHCPv4]
UseMTU=yes

EOF
```

**waagent**

We need to create a user in order to install packages from AUR.

```
useradd -m -G wheel -s /bin/bash arch
```

Impersonate the new user.

```
su arch
```

Install waagent from AUR.

```
mkdir ~/aur && cd ~/aur
```

```
git clone https://aur.archlinux.org/walinuxagent.git
```

```
cd walinuxagent
```

```
makepkg -risc
```

Stop user impersonation.

```
exit
```

Remove user.

```
userdel -r arch
```

Update waagent config (these settings favour cloud-init).

```
nano /etc/waagent.conf
```

```
Provisioning.Agent=cloud-init
Provisioning.DeleteRootPassword=y
Provisioning.DecodeCustomData=n
Provisioning.ExecuteCustomData=n
ResourceDisk.Format=n
ResourceDisk.EnableSwap=n
```

**cloud-init**

Disable cloud-init from applying networking (it's not reliable).

```
cat << EOF > /etc/cloud/cloud.cfg.d/20-disable-config-network.cfg
network:
  config: disabled

EOF
```

Mount the resource disk in the right place (not directly on /mnt).

```
cat << EOF > /etc/cloud/cloud.cfg.d/30-resource-disk.cfg 
mounts:
  - [ ephemeral0, /mnt/resource ]

EOF
```

Configure a swap file.

```
cat << EOF > /etc/cloud/cloud.cfg.d/40-enable-swap.cfg 
swap:
  filename: /mnt/resource/swapfile
  size: "auto"
  maxsize: 4294967296

EOF
```

**Check fstab**

The generated fstab was not correct (due to our disk mount points). Update to use sda1 for root and other partitions if we created them.

```
nano /etc/fstab
```

```
# <file system> <dir> <type> <options> <dump> <pass>
/dev/sda1           /         ext4      rw,relatime0 1
```

**Serial console**

We need to tell the kernel to output to serial and we need to tell grub to output to serial. The kernel supports a parameter to do this called `console=` meaning we can use `/etc/default/grub` to setup both. See above for the grub configuration.

> Note: Azure serial console expects device ttyS0 and a baud rate of 115200 or 9600.

**Enable services**

To make sure the needed services are started at boot enable them with systemctl.

```
systemctl enable sshd cloud-init waagent systemd-networkd systemd-resolved
```

## Generalise

Generalise the installation before exiting chroot and un-mounting the disk.

```
cloud-init clean
rm /etc/netplan/*
rm /run/systemd/network/* 
```

```
waagent --deprovision+user
```

```
exit
```

```
umount /mnt
```

> Note: There is no need to shutdown the VM as we will simply detach the disk in Azure.

# Create Azure Image 

Detach the disk where arch linux was installed.

```
<use the azure portal>
```

After detaching the disk generate a sas token so we can access it using azcopy; do this from the Azure Cloud Shell.

```
az disk grant-access -n <yourdiskname> -g <yourresourcegroupname> --access-level Read --duration-in-seconds 86400
```

Use azcopy to copy the managed disk to a blob in storage; do this from the Azure Cloud Shell.

```
azcopy copy "sas-URI-disk" "sas-URI-blob" --blob-type PageBlob
```

> Note: Get the sas token for the storage account container from the portal and don't forget to update it with the name of the blob you want to create.

Done with the disk sas token.

```
az disk revoke-access -n <yourdiskname> -g <yourresourcegroupname> 
```

Create a new Image resource and select the blob we just copied as the source.

```
<use the azure portal>
```

# Test Image

Create a new VM resource from the Image.

```
<use the azure portal>
```

Add custom data (cloud-init config) during VM creation to test cloud-init; example available in [src/custom-data](src/custom-data).

> Note: It is a good idea to move the resource disk to the /mnt/resource mount-point.

# Share Azure Image

If the VM boots successfully create a new Image Definition in a Shared Image Gallery to replicated it to any other region you want to deploy from.

# Make it stable

Keep it simple!
## Backups

## Upgrades

# Known issues

1. Cloud-init does not create swapfile.

https://bugs.launchpad.net/cloud-init/+bug/1869114

# Troubleshooting

## Network

Learn systemd-networkd and know where the different config paths are:

dir | description
---|---
/run/systemd/network/     | volatile runtime network directory.
/usr/lib/systemd/network/ | user network directory.
/etc/systemd/network/     | local administration network directory (highest priority).

Make sure the services are enabled.

```
systemctl enable systemd-networkd
```

```
systemctl start systemd-resolved
```

> Note: Remember systemd-networkd has its own internal dhcp client.