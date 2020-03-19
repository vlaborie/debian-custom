# Debian custom

## Dependencies

~~~
sudo apt install --yes --no-install-recommends git debootstrap parted btrfs-progs dosfstools cryptsetup-bin
~~~

## LUKS home

To create a LUKS /home wich wild be automatically mounted by libpam-mount:

~~~
cryptsetup luksFormat --label home /dev/XXX
cryptsetup luksOpen /dev/disk/by-label/home home
mkfs.ext4 /dev/mapper/home
cryptsetup luksClose home
~~~

## User password

User password can be defined in **config/passwd.local** with:

~~~
mkpasswd --method=sha-512 > config/passwd.local
~~~

It **must** be the same as your LUKS password for automounting /home with libpam-mount !

Default value is: **live**
