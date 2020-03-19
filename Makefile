UUID=$$(test -f cache/hostname || cat /proc/sys/kernel/random/uuid|head --bytes 13 > cache/hostname && cat cache/hostname)
PASSWORD=$$(test -f config/passwd.local && cat config/passwd.local || cat config/passwd)
DEBIAN_PROXY=$$(nc -z 127.0.0.1 3142 && printf "http://localhost:3142")
DEBIAN_REPO=$$(test -n $(DEBIAN_PROXY) && printf "$(DEBIAN_PROXY)/deb.debian.org/debian/" || printf "https://deb.debian.org/debian/")
DEBIAN_PACKAGES=$$(find config -type f -name "*.list.chroot"|xargs cat|xargs echo)

.PHONY: live qemu-live-bios qemu-live-uefi part install part chroot cleanchroot clean cleanall

live: output/debian-custom.iso

qemu-live-bios: output/debian-custom.iso
	qemu-system-x86_64 -boot d -m 512 -nographic -cdrom output/debian-custom.iso

qemu-live-uefi: output/debian-custom.iso
	qemu-system-x86_64 -m 512 -pflash /usr/share/qemu/OVMF.fd -cdrom output/debian-custom.iso

output/debian-custom.iso: cache/live/live/squashfs cache/live/boot/isolinux/isolinux.bin cache/live/boot/grub/efiboot.img
	xorriso -as mkisofs -V 'DEBIAN_CUSTOM' -o output/debian-custom.iso -J -J -joliet-long -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin -b boot/isolinux/isolinux.bin -c boot/isolinux/boot.cat -boot-load-size 4 -boot-info-table -no-emul-boot -eltorito-alt-boot -e boot/grub/efiboot.img -no-emul-boot -isohybrid-gpt-basdat -isohybrid-apm-hfsplus cache/live

cache/live/boot/isolinux/isolinux.bin:
	mkdir -p cache/live/boot/isolinux
	cp config/isolinux.cfg cache/live/boot/isolinux/isolinux.cfg
	cp /usr/lib/ISOLINUX/isolinux.bin cache/live/boot/isolinux/isolinux.bin
	cp /usr/lib/syslinux/modules/bios/ldlinux.c32 cache/live/boot/isolinux/ldlinux.c32

cache/live/boot/grub/efiboot.img: cache/live/boot/grub/grubx64.efi
	dd if=/dev/zero of=cache/live/boot/grub/efiboot.img bs=1M count=10
	mkfs.vfat cache/live/boot/grub/efiboot.img
	mmd -i cache/live/boot/grub/efiboot.img efi efi/boot
	mcopy -i cache/live/boot/grub/efiboot.img cache/live/boot/grub/grubx64.efi ::efi/boot/

cache/live/boot/grub/grubx64.efi:
	mkdir -p cache/live/boot/grub
	cp config/grub.cfg cache/live/boot/grub/grub.cfg
	grub-mkstandalone --format=x86_64-efi --output=cache/live/boot/grub/grubx64.efi --locales="" "boot/grub/grub.cfg=cache/live/boot/grub/grub.cfg"

cache/live/live/squashfs: chroot
	mkdir -p cache/live/live
	mountpoint -q cache/chroot/proc || mount -t proc proc cache/chroot/proc
	mountpoint -q cache/chroot/sys || mount -t sysfs sys cache/chroot/sys
	mountpoint -q cache/chroot/dev || mount -t devtmpfs dev cache/chroot/dev
	chroot cache/chroot /usr/bin/apt install live-boot --yes
	mountpoint -q cache/chroot/proc && umount cache/chroot/proc || true
	mountpoint -q cache/chroot/sys && umount cache/chroot/sys || true
	mountpoint -q cache/chroot/dev && umount cache/chroot/dev || true
	cp cache/chroot/vmlinuz cache/live/live/vmlinuz
	cp cache/chroot/initrd.img cache/live/live/initrd.img
	mksquashfs cache/chroot cache/live/live/filesystem.squashfs -e boot

install: part chroot
	mountpoint -q /mnt || mount /dev/disk/by-partlabel/$(UUID)-ROOTFS /mnt
	mountpoint -q /mnt/boot || mount /dev/disk/by-partlabel/$(UUID)-BOOT /mnt/boot
	mountpoint -q /mnt/boot/EFI || mount /dev/disk/by-partlabel/$(UUID)-EFI /mnt/boot/EFI
	rsync -av cache/chroot/ /mnt/
	mountpoint -q /mnt/proc || mount -t proc proc /mnt/proc
	mountpoint -q /mnt/sys || mount -t sysfs sys /mnt/sys
	mountpoint -q /mnt/dev || mount -t devtmpfs dev /mnt/dev
	[ -d "/sys/firmware/efi" ] && chroot /mnt /usr/bin/apt install grub-efi --yes || chroot /mnt /usr/bin/apt install grub-pc
	chroot /mnt /usr/sbin/update-grub2
	umount -R /mnt

part:
	bin/part $(UUID)

chroot: cleanchroot cache/debootstrap.tar.gz
	debootstrap --unpack-tarball=$(PWD)/cache/debootstrap.tar.gz buster cache/chroot $(DEBIAN_REPO)
	rsync -a --no-owner --no-group --chmod=u=rwX,go=rX config/chroot/ cache/chroot/
	rsync -a --no-owner --no-group --chmod=u=rwX,go=rX ./ cache/chroot/root/ --exclude=cache/* --exclude=output/*
	echo "$(UID)" > cache/chroot/etc/hostname
	sed -i "/^127.0.0.1/a 127.0.1.1\t$(UID)" cache/chroot/etc/hosts
	mountpoint -q cache/chroot/proc || mount -t proc proc cache/chroot/proc
	mountpoint -q cache/chroot/sys || mount -t sysfs sys cache/chroot/sys
	mountpoint -q cache/chroot/dev || mount -t devtmpfs dev cache/chroot/dev
	[ -z $(DEBIAN_PROXY) ] || echo "Acquire::http::Proxy \"$(DEBIAN_PROXY)/\";" > cache/chroot/etc/apt/apt.conf.d/proxy.conf
	[ -z $(DEBIAN_PROXY) ] || echo "Acquire::https::Proxy \"$(DEBIAN_PROXY)/\";" >> cache/chroot/etc/apt/apt.conf.d/proxy.conf
	chroot cache/chroot /usr/sbin/locale-gen
	DEBIAN_FRONTEND=noninteractive chroot cache/chroot /usr/bin/apt update
	DEBIAN_FRONTEND=noninteractive chroot cache/chroot /usr/bin/apt upgrade --yes
	DEBIAN_FRONTEND=noninteractive chroot cache/chroot /usr/bin/apt install --no-install-recommends --yes $(DEBIAN_PACKAGES)
	sed -i '/<!-- Volume definitions -->/a <volume user="user" fstype="auto" path="/dev/disk/by-label/home" mountpoint="/home" options="fsck,noatime"/>' cache/chroot/etc/security/pam_mount.conf.xml
	chroot cache/chroot /usr/sbin/useradd --home-dir /home/user --no-create-home --shell /usr/bin/zsh --groups sudo,dialout,audio,video user
	echo "user:$(PASSWORD)" | chroot cache/chroot /usr/sbin/chpasswd --encrypted
	[ -z $(DEBIAN_PROXY) ] || rm cache/chroot/etc/apt/apt.conf.d/proxy.conf
	mountpoint -q cache/chroot/proc && umount cache/chroot/proc || true
	mountpoint -q cache/chroot/sys && umount cache/chroot/sys || true
	mountpoint -q cache/chroot/dev && umount cache/chroot/dev || true

cache/debootstrap.tar.gz:
	debootstrap --merged-usr --make-tarball=cache/debootstrap.tar.gz --include=locales,ca-certificates buster cache/debootstrap $(DEBIAN_REPO)

cleanchroot:
	mountpoint -q cache/chroot/proc && umount cache/chroot/proc || true
	mountpoint -q cache/chroot/sys && umount cache/chroot/sys || true
	mountpoint -q cache/chroot/dev && umount cache/chroot/dev || true
	rm -rf cache/chroot

clean: cleanchroot
	rm -rf output/*

cleanall: clean
	rm -rf cache/*
