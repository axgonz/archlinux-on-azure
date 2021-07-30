#!/bin/bash

# Creates a fixed sized VHD from ISO rounded to the next MB
iso="archlinux-2021.07.01-x86_64.iso"
raw="archlinux-2021.07.01-x86_64.raw"
vhd="archlinux-2021.07.01-x86_64.vhd"

# Define 1MB in bytes
MB=$((1024*1024))

echo "Step 1: create vhd disk from iso file"
qemu-img convert -f raw -O vpc "$iso" "$vhd"

echo "Step 2: create raw disk from vhd file"
qemu-img convert -f vpc -O raw "$vhd" "$raw"

echo "Step 3: adjust raw disk size to prepare for vhd conversion"
rawsize=$(qemu-img info -f raw --output json "$raw" | \
       gawk 'match($0, /"virtual-size": ([0-9]+),/, val) {print val[1]}')

newsize=$((($rawsize/$MB + 1)*$MB))

echo "current size = $rawsize"
echo "rounded size = $newsize"
qemu-img resize -f raw "$raw" $newsize

echo "Step 4: create fixed vhd from raw disk"
qemu-img convert -f raw -o "subformat=fixed,force_size" -O vpc "$raw" "$vhd"

echo "Step 5: check the vhd disk size is divisable by 1MB"
vhdsize=$(qemu-img info -f raw --output json "$vhd" | \
       gawk 'match($0, /"virtual-size": ([0-9]+),/, val) {print val[1]}')

finalsize=$(($vhdsize/$MB))

echo "$vhdsize / $MB = $finalsize" 