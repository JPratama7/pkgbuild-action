FROM --platform=linux/amd64 archlinux:latest

RUN rm /etc/{pacman.conf,makepkg.conf.d/*}

COPY config/ /etc/config.makepkg/
COPY pacman.conf /etc/pacman.conf

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
