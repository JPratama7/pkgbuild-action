FROM --platform=linux/amd64 archlinux:latest

RUN rm /etc/{pacman.conf,makepkg.conf.d/*}

COPY config/ /etc/config.makepkg/
COPY pacman.conf /etc/pacman.conf

RUN pacman -Syyu --noconfirm archlinux-keyring reflector \
    && reflector --threads 10 -l 10 --delay 0.25 --protocol "https" -f 10 --sort rate -c CA,US --save /etc/pacman.d/mirrorlist \
    && pacman-key --init \
    && pacman-key --populate \
    && pacman -Syu --noconfirm --needed git base-devel wget \ 
    && rm -rf /var/cache/pacman/pkg

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
