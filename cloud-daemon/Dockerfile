FROM eclipse-temurin:21-jre-jammy

RUN groupadd -r amberd && useradd -r -g amberd -d /var/lib/amberd -s /sbin/nologin amberd \
    && mkdir -p /var/lib/amberd /opt/amberd/bin \
    && chown -R amberd:amberd /var/lib/amberd /opt/amberd \
    && chmod 0700 /var/lib/amberd

COPY build/libs/amberd-all.jar /opt/amberd/amberd-all.jar

RUN printf '#!/bin/sh\nexec java -XX:+UseZGC -Xmx768m -jar /opt/amberd/amberd-all.jar "$@"\n' > /usr/local/bin/amberd \
    && printf '#!/bin/sh\nexec java -cp /opt/amberd/amberd-all.jar app.amber.cloud.CliMainKt "$@"\n' > /usr/local/bin/amber-cli \
    && chmod +x /usr/local/bin/amberd /usr/local/bin/amber-cli

USER amberd
WORKDIR /var/lib/amberd

ENV AMBER_DATA_DIR=/var/lib/amberd
ENV AMBER_PORT=47821

EXPOSE 47821

ENTRYPOINT ["/usr/local/bin/amberd"]
CMD ["daemon", "--port", "47821"]
