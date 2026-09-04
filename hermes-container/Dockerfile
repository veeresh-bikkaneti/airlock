FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates git ripgrep curl jq \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

RUN useradd --create-home --shell /bin/bash hermes && \
    mkdir -p /workspace /workspace/output /home/hermes/.pi/agent && \
    chown -R hermes:hermes /workspace /home/hermes

COPY config/models.json /home/hermes/.pi/agent/models.json
COPY config/auth.json.template /home/hermes/.pi/agent/auth.json
COPY config/hermes-config.json.template /home/hermes/.pi/agent/config.json
COPY entrypoint.sh /entrypoint.sh

# entrypoint.sh is checked out CRLF on Windows (core.autocrlf=true) - the
# shebang's #!/bin/bash\r doesn't resolve inside the Linux container
# ("exec /entrypoint.sh: no such file or directory"), so strip \r before
# marking it executable.
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh && chown hermes:hermes /entrypoint.sh

USER hermes
WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
