#!/usr/bin/env bash
# Patches Wazuh's native shuffle.py integration script to accept Shuffle's
# self-signed HTTPS certificate.
#
# Why this is needed: shuffle.py calls
#   requests.post(url, data=msg, headers=headers, timeout=10)
# with no way to pass verify=False through the <integration> config in
# ossec.conf (the <options> tag only adds extra JSON fields to the outgoing
# message, it does not touch the request itself). Without this patch the
# integration fails with:
#   SSLCertVerificationError(1, '[SSL: CERTIFICATE_VERIFY_FAILED] ...')
# See ../TROUBLESHOOTING.md#13-wazuh-shuffle-integration-fails-on-shuffles-self-signed-cert
#
# CAUTION: this edits a file inside the running container's writable layer,
# not a host-mounted volume. The patch is LOST whenever the wazuh.manager
# container is recreated (docker compose up --force-recreate, down/up, a
# version bump, ...) and must be re-run afterwards. The real fix is to use a
# CA-signed certificate on the Shuffle side, or to fork/maintain a patched
# integration script in this repo and mount it over the stock one.
#
# Usage: ./patch-shuffle-ssl.sh [container_name]
set -euo pipefail

CONTAINER="${1:-single-node-wazuh.manager-1}"
SCRIPT_PATH="/var/ossec/integrations/shuffle.py"

echo "Patching ${SCRIPT_PATH} inside ${CONTAINER} to skip TLS verification..."

docker exec -it "${CONTAINER}" sed -i \
  "s/requests.post(url, data=msg, headers=headers, timeout=10)/requests.post(url, data=msg, headers=headers, timeout=10, verify=False)/" \
  "${SCRIPT_PATH}"

echo "Restarting wazuh-control to reload the integration..."
docker exec -it "${CONTAINER}" /var/ossec/bin/wazuh-control restart

echo "Done. Tail integrations.log to confirm:"
echo "  docker exec -it ${CONTAINER} tail -f /var/ossec/logs/integrations.log"
