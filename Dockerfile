FROM archlinux:latest

RUN rm /etc/pacman.conf

COPY config /etc/config.makepkg
COPY pacman.conf /etc/pacman.conf

RUN pacman -Syyu --noconfirm archlinux-keyring reflector \
    && pacman-key --init \
    && pacman-key --populate \
    && reflector --ipv4 --ipv6 -l 10 -f 10 -a 10 --protocol http,https --sort rate --save /etc/pacman.d/mirrorlist
RUN pacman -Syyuu --noconfirm --needed git base-devel aria2-git

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
