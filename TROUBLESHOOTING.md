# Journal de troubleshooting

Le [README](README.md) ne retient que les points les plus intéressants. Ce fichier liste
l'intégralité des problèmes rencontrés en construisant ce lab, dans l'ordre où ils sont
apparus : symptôme, diagnostic, cause racine, correctif.

## Sommaire

1. [Splunk refuse de démarrer (license terms)](#1-splunk-refuse-de-démarrer-license-terms)
2. [Event 4769 introuvable dans Wazuh](#2-event-4769-introuvable-dans-wazuh)
3. [Événement Wazuh perdu sous charge (eventRecordID)](#3-événement-wazuh-perdu-sous-charge-eventrecordid)
4. [Splunk crash-loop : instructions CPU AVX manquantes](#4-splunk-crash-loop--instructions-cpu-avx-manquantes)
5. [Suricata ne voit aucun trafic Kerberos](#5-suricata-ne-voit-aucun-trafic-kerberos)
6. [Dérive d'horloge Kerberos (KRB_AP_ERR_SKEW)](#6-dérive-dhorloge-kerberos-krb_ap_err_skew)
7. [Corruption de la stack après un clone dupliqué imbriqué](#7-corruption-de-la-stack-après-un-clone-dupliqué-imbriqué)
8. [Shuffle bloqué sur "Waiting for the database"](#8-shuffle-bloqué-sur-waiting-for-the-database)
9. [Shuffle : workflows bloqués sur EXECUTING indéfiniment](#9-shuffle--workflows-bloqués-sur-executing-indéfiniment)
10. [Shuffle : mauvaise syntaxe de variable ($exec)](#10-shuffle--mauvaise-syntaxe-de-variable-exec)
11. [Première exécution Shuffle bloquée ~16 minutes](#11-première-exécution-shuffle-bloquée-16-minutes)
12. [Intégration Wazuh → Shuffle : aucune activité dans integrations.log](#12-intégration-wazuh--shuffle--aucune-activité-dans-integrationslog)
13. [Wazuh → Shuffle : échec sur le certificat auto-signé de Shuffle](#13-wazuh--shuffle--échec-sur-le-certificat-auto-signé-de-shuffle)
14. [Mauvais nom d'intégration (custom-shuffle)](#14-mauvais-nom-dintégration-custom-shuffle)

---

## 1. Splunk refuse de démarrer (license terms)

**Symptôme** : le conteneur Splunk s'arrête immédiatement après `docker compose up -d`,
avec une erreur liée aux conditions de licence non acceptées.

**Cause** : l'image `splunk/splunk` exige explicitement l'acceptation des "Splunk
General Terms" via une variable d'environnement dédiée, en plus de `SPLUNK_START_ARGS`.

**Correctif** :
```yaml
environment:
  - SPLUNK_START_ARGS=--accept-license
  - SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-your-own-risk
```

---

## 2. Event 4769 introuvable dans Wazuh

**Symptôme** : après avoir lancé l'attaque Kerberoasting, aucun event 4769 (demande de
ticket de service) n'apparaît dans Wazuh, alors que l'audit policy "Kerberos Service
Ticket Operations" est bien active sur le DC.

**Diagnostic** :
- Confirmation côté Windows (Event Viewer) que l'event 4769 est bien généré localement
- Vérification qu'aucun event avec `serviceName: test` (le SPN ciblé) n'apparaît dans
  Wazuh (`docker exec ... grep` sur `alerts.json`)
- Confirmation que d'autres events 4769 "normaux" (comptes machine) arrivent bien

**Cause** : ce symptôme a deux origines distinctes selon le moment où il apparaît
(voir aussi le point 3 pour la variante sous charge) — ici, une période où l'agent
Wazuh n'avait tout simplement pas encore resynchronisé son flux après un redémarrage
de VM.

**Correctif** : relancer l'attaque après avoir confirmé `wazuh-control status` propre
côté agent et manager.

---

## 3. Événement Wazuh perdu sous charge (eventRecordID)

**Symptôme** : l'event 4769 précis de l'attaque manque ponctuellement, alors que
d'autres events 4769 proches dans le temps arrivent normalement.

**Diagnostic** :
- Comparaison des `eventRecordID` générés côté Windows (Event Viewer, onglet Details)
  avec ceux effectivement reçus par le manager Wazuh (`docker exec ... tail -f` sur
  `alerts.json` pendant une nouvelle exécution de l'attaque)
- Un trou numérique apparaît dans la séquence côté Wazuh exactement sur l'ID de
  l'event de l'attaque

**Cause racine** : sous forte rafale d'événements simultanés (l'attaque Kerberoasting
génère plusieurs authentifications/tickets en quelques millisecondes), l'agent Windows
de Wazuh peut perdre un event précis au lieu de le mettre en file. Ce n'est pas un
problème de règle ou de configuration : l'event n'atteint simplement jamais le manager.

**Correctif / contournement** : pas de fix définitif côté agent dans ce lab — la
détection reste fiable car Suricata capture la même attaque indépendamment côté
réseau (voir le README, section Suricata), ce qui illustre justement l'intérêt de ne
pas dépendre d'une seule source de détection.

**Méthode de diagnostic réutilisable** : comparer le volume (et si possible les ID)
d'événements entre la source (Event Viewer) et ce qui est effectivement indexé
(Wazuh Discover) plutôt que de se fier uniquement à "je ne vois rien dans le
dashboard".

---

## 4. Splunk crash-loop : instructions CPU AVX manquantes

**Symptôme** : le conteneur Splunk redémarre en boucle après quelques secondes,
sans message d'erreur clair au premier abord.

**Diagnostic** : lecture des logs internes Ansible du conteneur (`docker logs splunk`)
révélant un crash de `mongod`, le moteur KVStore embarqué par Splunk Enterprise.

**Cause racine** : les versions récentes de Splunk embarquent un MongoDB qui requiert
le jeu d'instructions CPU AVX. Le CPU virtualisé de la VM ne l'expose pas. La variable
`SPLUNK_SKIP_PREINSTALL_CPU_CHECKS_CORRUPTING_DATA_IF_UNSUPPORTED=1` ne corrige rien :
elle ne saute que la vérification au moment de l'installation, pas l'exigence réelle
au runtime — `mongod` plante quand même.

**Correctif** : épingler une version de Splunk antérieure à cette exigence :
```yaml
image: splunk/splunk:8.2.12
```
puis repartir sur des volumes propres (`docker compose down -v && docker compose up -d`).

---

## 5. Suricata ne voit aucun trafic Kerberos

**Symptôme** : les compteurs `krb5_tcp` / `krb5_udp` de Suricata restent à 0 malgré
des attaques Kerberoasting lancées en boucle.

**Diagnostic** : `tcpdump -i enp0s8 port 88` sur la VM Ubuntu (hôte Suricata) ne capture
strictement rien pendant que l'attaque tourne sur Kali.

**Cause racine** : le switch virtuel host-only de VirtualBox ne réplique pas par défaut
le trafic unicast entre deux VMs invitées (Kali, DC) vers une troisième VM (Ubuntu) qui
n'est ni source ni destination du paquet — contrairement à un vrai switch physique en
mode miroir, ou à un hub.

**Correctif** : activer le mode promiscuité des deux côtés :
- Dans VirtualBox : Réglages de la VM → Réseau → Carte host-only → Mode promiscuité →
  **Tout autoriser**
- Dans la VM Ubuntu : `sudo ip link set enp0s8 promisc on`

Confirmé ensuite par `tcpdump -i enp0s8 port 88 -n -v` montrant le handshake TCP puis
l'échange Kerberos (voir le README pour l'extrait de capture).

---

## 6. Dérive d'horloge Kerberos (KRB_AP_ERR_SKEW)

**Symptôme** : `GetUserSPNs.py` échoue avec une erreur `KRB_AP_ERR_SKEW` après
plusieurs redémarrages successifs des VMs.

**Cause** : Kerberos refuse toute authentification si l'écart d'horloge entre le
client et le contrôleur de domaine dépasse la tolérance configurée (5 minutes par
défaut) — un simple drift d'horloge après suspension/reprise de VM suffit à le
déclencher.

**Correctif** : resynchroniser manuellement l'horloge de Kali sur celle du DC :
```bash
sudo ntpdate 192.168.171.20
```

---

## 7. Corruption de la stack après un clone dupliqué imbriqué

**Symptôme** (survenu après une migration vers un nouveau PC) : l'indexer Wazuh
refuse de démarrer, avec d'abord une erreur de version de codec Lucene
(`Lucene912` introuvable), puis une erreur fatale `cannot downgrade a node from
version [2.19.6] to version [2.19.5]`. En parallèle, des erreurs TLS
`unknown_ca` apparaissent entre le manager, l'indexer et le dashboard.

**Diagnostic** :
```bash
grep "image:" docker-compose.yml
```
révèle deux versions différentes de l'image Wazuh (4.9.2 et 4.14.7) référencées dans
deux `docker-compose.yml` différents, qui pointaient en réalité vers les **mêmes**
volumes Docker.

**Cause racine** : un clone de `wazuh-docker` avait été accidentellement dupliqué de
façon imbriquée (un second clone du dépôt à l'intérieur du dossier `single-node` du
premier), chacun avec sa propre version d'image. Les deux stacks avaient tourné à des
moments différents sur les mêmes volumes partagés, désynchronisant les certificats
TLS et corrompant les métadonnées de l'indexer OpenSearch (incompatibilité de version
entre les segments écrits par les deux versions).

**Correctif** : reset complet plutôt qu'une réparation ciblée, jugée trop incertaine :
1. Suppression du dossier dupliqué entier
2. Nouveau `git clone` propre de `wazuh-docker` sur le tag `v4.14.7`
3. Régénération complète des certificats (`generate-indexer-certs.yml`)
4. Démarrage sur des volumes vierges (`docker compose down -v` puis `up -d`)
5. Vérification : `curl -k -u admin:<password> https://127.0.0.1:9200/_cluster/health`
   → `"status":"green"`

**Leçon** : toujours vérifier `docker compose config` ou `grep image: docker-compose.yml`
après une migration de machine, avant de relancer une stack multi-services qui partage
des volumes persistants.

---

## 8. Shuffle bloqué sur "Waiting for the database"

**Symptôme** : l'interface web de Shuffle reste bloquée en boucle sur "Waiting for the
Shuffle database to become available. This may take up to two minutes."

**Cause** : permissions insuffisantes sur le dossier `shuffle-database`, et/ou swap
activé sur l'hôte interférant avec OpenSearch (utilisé en interne par Shuffle).

**Correctif** (donné directement par l'écran d'erreur de Shuffle, et confirmé efficace) :
```bash
sudo chown -R 1000:1000 shuffle-database
sudo swapoff -a
sudo docker restart shuffle-opensearch
```

---

## 9. Shuffle : workflows bloqués sur EXECUTING indéfiniment

**Symptôme** : toute exécution de workflow reste bloquée sur le statut `EXECUTING`,
avec dans les logs d'Orborus :
```
Worker dispatch timeout
network shuffle_swarm_executions not found
This node is not a swarm manager
```

**Première piste (fausse)** : initialiser un vrai cluster Docker Swarm
(`docker swarm init`, création du réseau overlay `shuffle_swarm_executions`). Cela ne
résout pas le problème : Orborus tente ensuite sa propre initialisation interne du
Swarm, qui échoue à son tour sur une erreur d'adresse d'advertise.

**Cause racine réelle** (trouvée via `grep -A 30 "orborus:" docker-compose.yml | grep -i swarm`) :
la variable d'environnement `SHUFFLE_SWARM_CONFIG=run` du service `orborus`, prévue
pour des déploiements multi-nœuds à l'échelle, forçait une dépendance Docker Swarm
totalement inutile pour un lab mono-nœud.

**Correctif** : vider la variable plutôt que de monter un vrai Swarm :
```yaml
environment:
  - SHUFFLE_SWARM_CONFIG=
```
puis `docker compose up -d --force-recreate orborus`. Orborus fonctionne alors
normalement en Docker simple, sans aucune machinerie Swarm.

---

## 10. Shuffle : mauvaise syntaxe de variable ($exec)

**Symptôme** : le nœud "Change Me" du workflow échoue avec
`"error": "Failed finding 'exec . webhook_1 . body'"`.

**Cause** : syntaxe de référence de variable incorrecte tapée manuellement dans le
champ "Call" du nœud (`$exec.webhook_1.body`), au lieu d'utiliser le sélecteur de
variables intégré de Shuffle.

**Correctif** : les champs du payload JSON envoyé au webhook sont fusionnés directement
dans le contexte `$exec` — la bonne référence est simplement `$exec.<nom_du_champ>`
(ex: `$exec.test`), trouvable via le bouton `⊕` du champ plutôt qu'en la devinant.

---

## 11. Première exécution Shuffle bloquée ~16 minutes

**Symptôme** : la toute première exécution d'un workflow reste sur `EXECUTING` pendant
environ 16 minutes avant de passer à `FINISHED`, alors que les exécutions suivantes
se terminent en quelques secondes.

**Cause** : ce n'est pas un bug — Orborus doit télécharger les images Docker
`frikky/shuffle:app_sdk` et `ghcr.io/shuffle/shuffle-worker:latest` lors de la toute
première exécution. Une fois ces images en cache localement, les exécutions
suivantes sont quasi instantanées.

**Correctif** : aucun, comportement attendu au premier run.

---

## 12. Intégration Wazuh → Shuffle : aucune activité dans integrations.log

**Symptôme** : après configuration de l'intégration native `shuffle` dans
`ossec.conf`, `/var/ossec/logs/integrations.log` reste totalement vide, même en
déclenchant la règle manuellement.

**Diagnostic** :
- `wazuh-control status` montre `wazuh-integratord not running...`
- Lancer `wazuh-integratord -f` en premier plan affiche :
  `"Remote integrations not configured. Clean exit."`
- Cela révèle que le fichier `ossec.conf` édité sur l'hôte n'avait **jamais** été
  copié dans le conteneur en cours d'exécution : ce fichier n'est copié
  automatiquement qu'au tout premier démarrage d'un conteneur, pas à chaque
  `docker compose up -d`.

**Correctif** :
```bash
docker cp config/wazuh_cluster/wazuh_manager.conf \
  single-node-wazuh.manager-1:/var/ossec/etc/ossec.conf
docker exec single-node-wazuh.manager-1 /var/ossec/bin/wazuh-control restart
```
(un restart de processus dans le conteneur, pas une recréation du conteneur).

---

## 13. Wazuh → Shuffle : échec sur le certificat auto-signé de Shuffle

**Symptôme** : toujours aucune alerte côté Shuffle, mais `integrations.log` reste
silencieux même avec l'intégration correctement chargée.

**Diagnostic** : activation du mode debug (`integrator.debug=2` dans
`local_internal_options.conf` + restart), qui révèle dans les logs :
```
SSLCertVerificationError(1, '[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify
failed: self-signed certificate')
```
Lecture du script `/var/ossec/integrations/shuffle.py` : l'appel HTTP est codé en dur
`requests.post(url, data=msg, headers=headers, timeout=10)`, sans option de
vérification TLS exposée via la config XML (le tag `<options>` ne fait qu'ajouter des
champs JSON au message, il ne touche pas à la requête elle-même).

**Correctif** : patch direct du script dans le conteneur (voir
[`scripts/patch-shuffle-ssl.sh`](scripts/patch-shuffle-ssl.sh)) :
```bash
docker exec -it single-node-wazuh.manager-1 sed -i \
  "s/requests.post(url, data=msg, headers=headers, timeout=10)/requests.post(url, data=msg, headers=headers, timeout=10, verify=False)/" \
  /var/ossec/integrations/shuffle.py
docker exec -it single-node-wazuh.manager-1 /var/ossec/bin/wazuh-control restart
```

**Limite connue** : ce patch vit uniquement dans la couche writable du conteneur en
cours d'exécution, pas dans un volume monté — il est donc perdu si le conteneur
`wazuh.manager` est recréé (`--force-recreate`, `down`/`up`, montée de version...) et
doit être réappliqué à chaque fois. Une vraie correction pérenne utiliserait un
certificat signé par une CA côté Shuffle.

---

## 14. Mauvais nom d'intégration (custom-shuffle)

**Symptôme** : l'intégration ne produit aucun effet, sans erreur explicite.

**Cause** : le nom `<name>custom-shuffle</name>` indique à Wazuh de chercher un
script utilisateur nommé `custom-shuffle` dans `/var/ossec/integrations/` — script
qui n'existe pas, puisque l'intégration native officielle s'appelle simplement
`shuffle` (script `shuffle.py` déjà fourni par l'image Wazuh).

**Correctif** : utiliser le nom exact de l'intégration native :
```xml
<integration>
  <name>shuffle</name>
  <hook_url>http://IP:3001/api/v1/hooks/HOOK_ID</hook_url>
</integration>
```
confirmé via la documentation officielle Wazuh et des retours d'expérience tiers.
