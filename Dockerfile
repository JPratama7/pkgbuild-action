FROM archlinux:latest

RUN rm -v /etc/makepkg.conf
COPY makepkg.conf /etc/
RUN pacman -Syu --noconfirm --needed git base-devel

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
