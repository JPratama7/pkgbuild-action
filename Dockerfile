FROM archlinux:latest
RUN rm -v /etc/makepkg.conf
RUN rm -v /etc/pacman.conf

COPY makepkg.conf /etc/
COPY pacman.conf /etc/
RUN pacman -Syyu --noconfirm reflector && reflector --latest 10 --protocol http,https --sort rate --save /etc/pacman.d/mirrorlist
RUN pacman -Syu --noconfirm --needed git base-devel
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
