FROM alpine:3.20
RUN apk add --no-cache openssh-server \
 && ssh-keygen -A \
 && adduser -D -s /bin/sh jumper \
 && adduser -D -s /bin/sh deploy \
 && echo 'jumper:jump-test-password' | chpasswd \
 && echo 'deploy:target-test-password' | chpasswd \
 && mkdir -p /run/sshd /etc/ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
