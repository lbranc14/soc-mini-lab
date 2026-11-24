# Wazuh (SIEM/EDR)

This lab runs the official [`wazuh/wazuh-docker`](https://github.com/wazuh/wazuh-docker)
single-node stack, pinned to tag `v4.14.7`, rather than a hand-rolled compose
file: it's a multi-service stack (manager, indexer, dashboard) wired together
with generated TLS certs, and reproducing it by hand invites drift from the
upstream config. `docker-compose.override.yml` below only captures the deltas
this lab actually needed.

## Deploy

```bash
git clone --branch v4.14.7 https://github.com/wazuh/wazuh-docker.git
cd wazuh-docker/single-node
cp /path/to/this/docker-compose.override.yml .
docker compose -f generate-indexer-certs.yml run --rm generator
docker compose up -d
```

> Pin the exact tag. Running different versions of the manager/indexer/dashboard
> against the same volumes is what caused the stack-corruption incident in
> `../../TROUBLESHOOTING.md#7-stack-corruption-after-a-duplicated-nested-clone`.

## Enabling the Wazuh → Shuffle integration

Add the block in [`../../config/wazuh/ossec-shuffle-integration.xml`](../../config/wazuh/ossec-shuffle-integration.xml)
to `config/wazuh_cluster/wazuh_manager.conf`, then push it into the **running**
container (editing the host file alone does nothing — `ossec.conf` is only
copied in at first boot):

```bash
docker cp config/wazuh_cluster/wazuh_manager.conf \
  single-node-wazuh.manager-1:/var/ossec/etc/ossec.conf
docker exec single-node-wazuh.manager-1 /var/ossec/bin/wazuh-control restart
```

Shuffle's self-signed certificate will make the native `shuffle.py` integration
script fail silently (`SSLCertVerificationError`). Run
[`../../scripts/patch-shuffle-ssl.sh`](../../scripts/patch-shuffle-ssl.sh)
against the manager container afterwards — see
`../../TROUBLESHOOTING.md#13-wazuh-shuffle-integration-fails-on-shuffles-self-signed-cert`
for why, and note that this patch lives only in the container's writable layer:
it must be re-applied any time the `wazuh.manager` container is recreated.
