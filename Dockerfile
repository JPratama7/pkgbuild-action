FROM archlinux:latest

RUN rm /etc/{pacman.conf,makepkg.conf.d/*}

COPY config/ /etc/config.makepkg/
COPY pacman.conf /etc/pacman.conf

RUN pacman -Syyu --noconfirm archlinux-keyring reflector \
    && pacman-key --init \
    && pacman-key --populate \
    && pacman -Syu --noconfirm --needed git base-devel aria2-git \ 
    && reflector -n 8 -f 8 -l 8 -a 3 --threads 8 --sort rate --save /etc/pacman.d/mirrorlist \
    && rm -rf /var/cache/pacman/pkg

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
