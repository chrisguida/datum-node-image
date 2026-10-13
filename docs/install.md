# Installing the image on a VPS

One disk image, three containers, from the release page: `.img.gz` for DigitalOcean and
for downloading, `.img` (raw) for providers that import from a URL and want raw, `.qcow2`
for providers that want qcow2. The release's `SHA256SUMS` lists the three hashes and
`SHA256SUMS.asc` is the signature over that list; after downloading a file, `sha256sum <file>`
must print the hash in the list. The raw and qcow2 files are distributed by torrent (the
`.torrent` files are on the release page) with an HTTPS web seed, so any torrent client
gets them; the gzip is also a plain download from the release page.

Tested size: 2 vCPU, 4 GB RAM, 80 GB disk. 2 GB machines are not tested. The image boots
from BIOS and from UEFI, with VirtIO or IDE disks and VirtIO or e1000 network cards.

## DigitalOcean, from scratch

1. Control panel → **Backups & Snapshots** → **Custom Images** tab → **Import via URL**.
   Paste the `.img.gz` URL from the release page and click **Next**. (**Upload Image** from
   your computer works too; the file is about 770 MB.)
2. In the form: name the image after the release, **Distribution: Unknown**, pick the
   datacenter region where the droplet will live, **Upload Image**. The image shows as
   pending for a few minutes, then available.
3. **Create → Droplets**. Under **Choose an image** open the **Custom images** tab and pick
   it. Region: the one the image is in. Size: **Basic, 2 vCPU / 4 GB / 80 GB**.
   **Authentication: SSH key** (required: a custom-image droplet has password login off and
   no console password reset). Click **Create Droplet**.
4. The droplet is up about 30 seconds after it is created. In a browser open
   `https://<droplet IP>/` and accept the self-signed certificate warning. The setup page
   asks for the setup code.
5. The setup code is printed on the droplet's console: in the control panel open the
   droplet → **Access** → **Launch Droplet Console**. It is also in
   `/var/lib/node-wizard/setup-code` over SSH as root.
6. Finish the setup form (payout address, pool, password), then follow *After the first boot*.

Source: [DigitalOcean custom images: features](https://docs.digitalocean.com/products/custom-images/details/features/),
[uploading custom images](https://docs.digitalocean.com/products/custom-images/how-to/upload/).

## DigitalOcean, in place

This writes the image over an existing droplet's disk, keeping its IP. Everything on the
disk is lost. About 5 minutes.

1. SSH in as root and stop whatever writes to the disk:
   `systemctl stop <node and gateway units>; swapoff -a`.
2. Boot a NixOS installer that runs entirely from RAM (nix-community's kexec image):

       curl -fsSL -o kexec.tgz https://github.com/nix-community/nixos-images/releases/download/nixos-25.05/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz
       tar -xzf kexec.tgz && ./kexec/run

   The connection drops. About 30 seconds later the droplet answers SSH again as root with
   the same keys, from a system in memory; the disk is untouched and not mounted. The SSH
   host key is new, so delete the droplet's line from `~/.ssh/known_hosts` or connect with
   `-o StrictHostKeyChecking=no`.
3. Clear the old partition table's backup copy at the end of the disk, then write the image
   and read it back (the byte count is the raw image's size from `SHA256SUMS`' file list;
   for v2026.10.1-rc1 it is 5412749312):

       ssh root@<IP> 'S=$(blockdev --getsz /dev/vda); dd if=/dev/zero of=/dev/vda bs=512 seek=$((S-4096)) count=4096 status=none'
       zcat datum-node-image-generic-<commit>.img.gz | ssh root@<IP> 'dd of=/dev/vda bs=4M conv=fsync status=none; head -c <raw size> /dev/vda | sha256sum'

   The hash printed must equal the raw image's hash in `SHA256SUMS`. If it does not, do not
   reboot: something changed the file on the way.
4. `ssh root@<IP> reboot`. About 30 seconds later the droplet is running the image on the
   same IP. The host key changes once more.
5. Continue with *After the first boot*.

The first boot grows the root partition to the whole disk and takes the SSH key and
hostname from DigitalOcean's metadata, as a from-scratch droplet does.

## Vultr

Vultr imports a raw disk image from a public URL as a snapshot, then deploys instances from
it. Its requirements: raw format, x86-64, UEFI boot, VirtIO drivers, disk 150 GB or smaller.
The image meets all of them. Use the raw `.img` URL (the torrent's web seed URL works);
Vultr's documentation does not say it accepts gzip.

1. Console → **Products** → **Snapshots** → **Add Snapshot**. Enter the `.img` URL, mark it
   **UEFI** if the form has the option (the CLI has a `--uefi` flag for the same thing),
   click **Upload**. The download runs on Vultr's side; the snapshot shows as pending until
   it is done. The raw image is 5.4 GB on the wire, most of it zeros.
2. **Products** → **Compute** → **Deploy**. Choose a location, then under the image choice
   pick the **Snapshot** tab and the snapshot. Plan: 2 vCPU / 4 GB with an 80 GB or larger
   disk (the disk must be at least the snapshot's size). Pick your SSH key, deploy.
3. Open `https://<instance IP>/` and accept the certificate warning. The setup code is on
   the instance's console (**View Console** in the instance page), or in
   `/var/lib/node-wizard/setup-code` over SSH.
4. Continue with *After the first boot*.

Source: [Best practices when migrating to Vultr](https://docs.vultr.com/best-practices-when-migrating-to-vultr),
[vultr-cli snapshot create-url](https://docs.vultr.com/reference/vultr-cli/snapshot/create-url).

## LunaNode

LunaNode takes qcow2 images only, fetches them from a URL, and gives VMs IDE disks and an
e1000 network card unless the image is marked virtio. Use the `.qcow2` URL. Its API
documents custom images for the Toronto region only.

1. Panel → **Images** → **Add a New Image**. Give it the qcow2 URL, format **qcow2**, a name
   with the release in it, region **Toronto**, and **virtio: yes** if the form offers it.
   (The API call is `image/fetch` with `region=toronto`, `format=qcow2`, `virtio=yes`.)
   If the panel only takes an upload, download the `.qcow2` first and upload it.
2. Wait for the image to show as ready.
3. Create a VM: 4 GB plan, Toronto, and under **My Images** pick the image. Add your SSH key
   if the form offers one.
4. Open `https://<VM IP>/` and accept the certificate warning. The setup code is on the
   VM's console (panel → the VM → **VNC**), or in `/var/lib/node-wizard/setup-code` over SSH.
5. Continue with *After the first boot*.

Source: [LunaNode images](https://www.lunanode.com/features/images),
[LunaNode API: images](https://www.lunanode.com/api/image).

## After the first boot

The same checks on every provider. On a 2 vCPU / 4 GB machine the UTXO snapshot is loaded
about 20 minutes after power-on. The node then has to sync every block mined since the
snapshot before the gateway hands out its first job, and it does that at roughly 16 blocks a
minute while background validation runs alongside: with the 976,000 snapshot (October 7)
count on about an hour more per week of snapshot age.

1. **Setup page.** `https://<IP>/` redirects to `/setup` and asks for the setup code, a
   password, a payout address and a pool. After the form it goes to `/status`.
2. **SSH.** `ssh root@<IP>` with the key you gave the provider. If it is refused, the
   provider's metadata did not reach cloud-init; use the provider's console instead. Nothing
   else needs SSH.
3. **Disk and services.** `df -h /` shows the whole disk, not 5 GB; `systemctl --failed`
   lists nothing.
4. **Snapshot fast start.** `/status` shows the snapshot download (BitTorrent, 3 to 10
   minutes), then the load (15 to 20 minutes), then the gateway starting. The gateway logs
   "Could not fetch new template" and "Did not see an initial stratum job" until the node
   has caught up to the chain tip; that is expected. The stratum port (23334) opens with
   the first job.
5. **Update page.** `/update` shows *Built from (git revision)* equal to the release's
   commit, *Image variant* `generic` or `generic-qcow2`, and *Running* `assumeutxo-976000`.
   While the node is in background validation the *Switch to official* button is greyed
   out; that is correct.

If something on this list fails on your provider, open an issue with the provider, the
step, and what the console showed.
