#!/bin/bash
pushd "$(dirname $0)" >/dev/null 2>&1

HOSTNAME="risnix"

function log() {
	echo -e "\n\e[90m--<\e[36m<\e[96m<\e[33m" $@ "\e[96m>\e[36m>\e[90m>--\e[0m"
}

STAGE="$1"
if [ "$STAGE" = "" ]; then
	STAGE="1"
fi

# BUILD DOCKER ENV
if [ "$STAGE" = "1" ]; then

	log "STAGE 1"

	log Build docker container.
	docker build -t risnix .

	log Run docker container
	docker run --privileged -v $PWD:/root/build -t risnix

	log Docker stopped.
fi

if [ "$STAGE" = "2" ]; then

	log "STAGE 2 (in docker env)"

	log Debootstrapping.
	if [ ! -e chroot ]; then
		debootstrap --arch=amd64 --variant=minbase jessie chroot http://ftp.se.debian.org/debian
	fi

	cp run.sh chroot/root/run.sh

	log Mount dev to chroot/dev
	mount -o bind /dev chroot/dev

	log "Start chroot (stage 3)."
	chroot chroot /root/run.sh 3

	log "Start stage 4"
	./run.sh 4
fi

if [ "$STAGE" = "3" ]; then
	log "STAGE 3 (in chroot env)"

	mount none -t proc /proc
	mount none -t sysfs /sys 
	mount none -t devpts /dev/pts

	log Install kernel.
	apt-get install -y linux-image-amd64

	log Set machine ID.
	if [ ! -e /var/lib/dbus/machine-id ]; then
		if [ -e /etc/machine-id ]; then
			mkdir -p /var/lib/dbus
			cp /etc/machine-id /var/lib/dbus/machine-id
		else 
			apt-get install dialog dbus --yes --force-yes
			mkdir -p /var/lib/dbus
			dbus-uuidgen > /var/lib/dbus/machine-id
		fi
	fi
	if [ ! -e /etc/machine-id ]; then
		cp /var/lib/dbus/machine-id /etc/machine-id
	fi

	log Set hostname.
	if [ "$(cat /etc/hostname)" != "$HOSTNAME" ]; then
		echo "$HOSTNAME" >/etc/hostname
	fi
	echo "127.0.0.1	$(cat /etc/hostname)" >>/etc/hosts

	log Create user and fix permissions.
	useradd -m user -s /bin/bash
	mkdir -p /etc/systemd/system/getty@tty1.service.d
	cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf <<_EOF_
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin user --noclear %I 38400 linux
_EOF_
	cat >/etc/systemd/system/getty@tty1.service.d/noclear.conf <<_EOF_
[Service]
TTYVTDisallocate=no
_EOF_
	cat >/etc/systemd/logind.conf <<_EOF_
[Login]
NAutoVTs=1
ReserveVT=1
#KillUserProcesses=no
#KillOnlyUsers=
#KillExcludeUsers=root
#InhibitDelayMaxSec=5
#HandlePowerKey=poweroff
#HandleSuspendKey=suspend
#HandleHibernateKey=hibernate
#HandleLidSwitch=suspend
#PowerKeyIgnoreInhibited=no
#SuspendKeyIgnoreInhibited=no
#HibernateKeyIgnoreInhibited=no
#LidSwitchIgnoreInhibited=yes
#IdleAction=ignore
#IdleActionSec=30min
#RuntimeDirectorySize=10%
#RemoveIPC=yes
_EOF_
	apt-get install sudo
	cat >/etc/sudoers.d/999-nopasswd <<_EOF_
user   ALL=(ALL:ALL) NOPASSWD:ALL
_EOF_

	log Install kernel and live boot stuff.
	apt-get install -y \
		linux-image-amd64 \
		live-boot

	log Random hostname on boot
	cat >/etc/rc.local <<_EOF_
#!/bin/bash

# Add random yada yada after hostname
HOSTNAME="\$(hostname)\$(< /dev/urandom tr -dc 0-9 | head -c1)\$(< /dev/urandom tr -dc a-z0-9 | head -c9)"
echo "\$HOSTNAME" >/etc/hostname
echo "127.0.0.1 \$HOSTNAME" >>/etc/hosts

/usr/local/sbin/tinc_runner.sh &
_EOF_
	chmod a+x /etc/rc.local

	log Install tinc
	apt-get -y install build-essential gzip tar wget liblzo2-dev lib32z1-dev lib32ncurses5-dev libreadline-dev libssl-dev
	pushd /tmp >/dev/null
	wget https://www.tinc-vpn.org/packages/tinc-1.1pre14.tar.gz
	tar xzvf tinc-1.1pre14.tar.gz
	rm tinc-1.1pre14.tar.gz
	pushd tinc-1.1pre14 >/dev/null
	./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-legacy-protocol
	make
	make install
	popd
	popd
	mkdir -p /etc/tinc/risnix/hosts

	log Tinc invitation script
	apt-get -y install curl jq
	cat >/usr/local/sbin/get_tinc_invite.sh <<_EOF_
#!/bin/bash

server="\$(cat /lib/live/mount/medium/risnix/config.json | jq -r .tinc.server )"
keyid="\$(cat /lib/live/mount/medium/risnix/config.json | jq -r .tinc.key_id )"
secretkey="\$(cat /lib/live/mount/medium/risnix/config.json | jq -r .tinc.secret_key )"

time="\$(LC_ALL=C LANG=en date +"%a, %d %b %Y %T %z")"
nonce="\$(openssl rand 63 -hex)"
method="POST"
path="/invitation/\$(hostname)"
body=""
hexval="\$nonce\$(echo -n \$method\$path\$body\$time | xxd -p | tr -d "\\n")"
hash="\$(echo -n "\$hexval" | xxd -r -p | openssl dgst -sha512 -mac HMAC -macopt key:\$secretkey | cut -d" " -f2)"
authheader="Authorization: ss1 keyid=\$keyid, hash=\$hash, nonce=\$nonce"

curl -v -v -X "\$method" -H "Accept: text/plain" -H "\$authheader" -H "Date: \$time" -d "\$body" "http://\$server\$path" 2>&1 | grep '^< Location:' | sed -r 's/^[^:]+: //' | sed 's/\r$//'
_EOF_
	chmod a+x /usr/local/sbin/get_tinc_invite.sh

	apt-get -y install mawk
	cat >/usr/local/sbin/tinc_runner.sh <<_EOF_
#!/bin/bash
while true; do
	if [ ! -e /etc/tinc/risnix/tinc.conf ]; then
		while [ ! -e /etc/tinc/risnix/tinc.conf ]; do
			invite="\$(get_tinc_invite.sh)"
			if [ "\$invite" != "" ]; then
				tinc -n risnix join "\$invite"
			else
				sleep 10
			fi
		done
		echo "AddressFamily = ipv4" >>/etc/tinc/risnix/tinc.conf
		echo "AutoConnect = yes" >>/etc/tinc/risnix/tinc.conf
		echo "DeviceType = tap" >>/etc/tinc/risnix/tinc.conf
		echo "LocalDiscovery = yes" >>/etc/tinc/risnix/tinc.conf
		echo "GraphDumpFile = /var/log/tincgraph.dump" >>/etc/tinc/risnix/tinc.conf
		echo "PingInterval = 20" >>/etc/tinc/risnix/tinc.conf
		echo "PingTimeout = 5" >>/etc/tinc/risnix/tinc.conf
	fi
	if [ "\$(ps waux | grep tinc | grep risnix | grep -v grep)" == "" ]; then
		tinc -n risnix start
	fi
	if [ "\$(ip addr | grep risnix)" != "" ] ; then
		if [ "\$(ip addr show risnix | grep "inet\\b" | awk '{print \$2}' | cut -d/ -f1)" == "" ]; then
			if [ -e /run/dhclient.risnix.pid ]; then
				kill \$(cat /run/dhclient.risnix.pid)
				rm -f /run/dhclient.risnix.pid
			fi
			dhclient -pf /run/dhclient.risnix.pid -lf /var/lib/dhcp/dhclient.risnix.leases risnix
		fi
	fi
	sleep 10
done
_EOF_
	chmod a+x /usr/local/sbin/tinc_runner.sh

	log Network tooling
	apt-get -y install iputils-arping iputils-ping traceroute

	log Convenience stuff nice to have
	apt-get -y install screen vim

	log Clean up chroot.
	apt-get clean
	rm -rf /tmp/* /var/spool/*
	umount -lf /proc
	umount -lf /sys 
	umount -lf /dev/pts

	log Leaving chroot.
fi

if [ "$STAGE" = "4" ]; then
	log "STAGE 4 (back in docker env)"

	log Unmount chroot/dev
	umount -lf chroot/dev

	rm chroot/root/run.sh

	log Make directories that will be copied to our bootable medium.
	mkdir -p image/{live,isolinux}

	log Compress the chroot environment into a Squash filesystem.
	if [ ! -e image/live/filesystem.squashfs ]; then
		mksquashfs chroot image/live/filesystem.squashfs -e boot
	fi

	log Prepare USB/CD bootloader
	if [ ! -e image/live/vmlinuz ]; then
		cp chroot/boot/vmlinuz-* image/live/vmlinuz
	fi
	if [ ! -e image/live/initrd ]; then
		cp chroot/boot/initrd.img-* image/live/initrd
	fi
	mkdir -p image/isolinux
	cat >image/isolinux/isolinux.cfg <<_EOF_
UI menu.c32

prompt 0
menu title Boot Menu

timeout 40

label risnix
menu label ^Risnix
menu default
kernel /live/vmlinuz
append initrd=/live/initrd boot=live

label hdt
menu label ^Hardware Detection Tool (HDT)
kernel /hdt.c32
text help
HDT displays low-level information about the systems hardware.
endtext

label memtest86+
menu label ^Memory Failure Detection (memtest86+)
kernel /memtest
_EOF_
	if [ ! -e usb.img ]; then
		log Create usb image file
		dd if=/dev/zero of=usb.img bs=1M count=300

		log Partition usb image file
		echo -e "o\nn\np\n1\n\n\na1\nw" | fdisk usb.img
		SECTOR_SIZE="$(fdisk -lu usb.img | grep ^Units: | sed 's/.*= //' | sed 's/ .*$//')"
		PARTITION_START="$(fdisk -lu usb.img | grep usb.img1 | sed 's/usb.img1 *\* *//' | sed 's/ .*$//')"
		OFFSET="$(( $SECTOR_SIZE * $PARTITION_START ))"

		syslinux -i usb.img

		if [ ! -e /dev/loop0 ]; then
			mknod /dev/loop0 b 7 0
		fi

		log Mount usb image file as loop device
		losetup -o $OFFSET /dev/loop0 usb.img

		log Format FAT32 on usb image file
		apt-get install -y dosfstools
		mkfs.vfat /dev/loop0

		log Install syslinux to usb image
		syslinux -i /dev/loop0

		log Write syslinux master boot record to usb image
		dd if=/usr/lib/syslinux/mbr/mbr.bin of=usb.img conv=notrunc bs=440 count=1

		log Mount first usb image partition
		mount /dev/loop0 /mnt

		log Copy data to image partition
		cp /usr/lib/syslinux/modules/bios/* /mnt/
		cp /usr/share/misc/pci.ids /mnt/
		cp /boot/memtest86+.bin /mnt/memtest
		cp image/isolinux/isolinux.cfg /mnt/syslinux.cfg
		rsync -rv image/live /mnt/

		log risnix configuration file
		mkdir /mnt/risnix
		if [ -e config.json ]; then
			cp config.json /mnt/risnix/config.json
		else
			cat >/mnt/risnix/config.json <<_EOF_
{
	"tinc": {
		"server": "tinchost.example.org",
		"key_id": "mykey",
		"secret_key": "topsecret"
	}
}
_EOF_
		fi

		log Unmount first usb image partition
		umount -lf /mnt
		
		log Unmount usb image file as loop device
		losetup -d /dev/loop0
	fi
fi

popd >/dev/null 2>&1
