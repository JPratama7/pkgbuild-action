FROM archlinux:latest

RUN rm /etc/{pacman.conf,makepkg.conf.d/*}

COPY config/ /etc/config.makepkg/
COPY pacman.conf /etc/pacman.conf

RUN pacman -Syyu --noconfirm archlinux-keyring reflector \
    && pacman-key --init \
    && pacman-key --populate \
    && reflector --ipv4 --ipv6 -l 10 -f 10 -a 4 --protocol http,https --sort rate --save /etc/pacman.d/mirrorlist \
    && pacman -Syu --noconfirm --needed git base-devel aria2-git \ 
    && rm -rf /var/cache/pacman/pkg

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
