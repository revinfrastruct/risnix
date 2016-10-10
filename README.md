# risnix

This is a live Linux distro, running the Revolutionary Infrastructure.

Scale your cluster up, by just booting more machines on the USB.

* Built on Debian Jessie.
* Tinc VPN connects your machines together.
* Puppet agent will connect to a Puppet server (on the VPN) for further config.

## Getting started

1. Download the USB image.
2. Copy the image file onto an USB stick.
3. Mount the USB stick and find the `config.json` file in the `risnix` directory.
4. Edit the `config.json` file. (More info below.)
5. Now, boot a machine on the USB device.

## Build the USB image.

The build was made for running within docker, so you need docker.
The `run.sh` script will do most magic and generate a `usb.img` image file.

## Prerequisites

You need at least one server with:

* Your Tinc VPN up and running.
* [tincinvite](https://github.com/alfreddatakillen/tincinvite) for serving
invitations to the tinc vpn.
* Some DHCP Server for providing IPs to machines that connects to your VPN.

On the VPN, you will also need at least one Puppet server.

## Configuration (the `config.json` file)

### `tinc.server`

The IP or hostname of a server that will provide a Tinc network invitation.

You can only define one IP or hostname. Use roundrobin DNS if you want
redundancy/fallbacks.

### `tinc.key_id` and `tinc.secret_key`

Those are the shared secrets that will be used to authorize the connection
between this machine and the `tinc.server` machine.

It is extremely important to keep the `tinc.secret_key` secret. Anyone who has
this password will be able to join the VPN.


