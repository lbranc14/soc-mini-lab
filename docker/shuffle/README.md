# Shuffle (SOAR)

Deployed from the official [`Shuffle/Shuffle`](https://github.com/Shuffle/Shuffle)
repository's `docker-compose.yml` (backend, frontend, opensearch, orborus,
security — too many interdependent services to usefully reproduce by hand
here). `docker-compose.override.yml` below is the one fix this lab actually
needed on top of that.

## Deploy

```bash
git clone https://github.com/Shuffle/Shuffle.git shuffle
cd shuffle
cp /path/to/this/docker-compose.override.yml .
sudo chown -R 1000:1000 shuffle-database
sudo swapoff -a
docker compose up -d
```

## The Orborus / Swarm trap

Out of the box, the `orborus` service ships with `SHUFFLE_SWARM_CONFIG=run`,
which is meant for scaled, multi-node deployments. On a single Docker host
with no Swarm cluster, this makes every workflow execution hang on
"EXECUTING" and Orborus loop on errors like:

```
Worker dispatch timeout
network shuffle_swarm_executions not found
This node is not a swarm manager
```

It is tempting to actually run `docker swarm init` to satisfy this, but
Orborus's own internal swarm bootstrap still fails on a single-node lab
(advertise-address errors) — Swarm isn't the fix, dropping the Swarm
requirement is. `docker-compose.override.yml` clears that env var; apply it
and force-recreate the container:

```bash
docker compose up -d --force-recreate orborus
```

See `../../TROUBLESHOOTING.md#11-shuffle-workflows-stuck-executing-forever`
for the full diagnosis.
