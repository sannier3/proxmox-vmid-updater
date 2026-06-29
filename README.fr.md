# Proxmox VMID Updater

Renommage **sûr et transactionnel** du **VMID** d'une VM QEMU ou d'un conteneur LXC sur Proxmox VE - configuration, volumes de stockage, snapshots, sauvegardes, HA et pare-feu inclus.

**__Langues du Readme__** [![Français](https://img.shields.io/badge/lang-Français-blue.svg)](README.fr.md) [![English](https://img.shields.io/badge/lang-English-lightgrey.svg)](README.md) ![Licence](https://img.shields.io/badge/Licence-GPLv3-success?style=flat-square)

![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-8.x%2B-E57000?style=flat-square) ![Bash](https://img.shields.io/badge/Bash-script-4EAA25?style=flat-square&logo=gnubash&logoColor=white) ![Version](https://img.shields.io/badge/version-1.3.0-informational?style=flat-square)

---

> [!WARNING]
> Ce script renomme des VMID et déplace de **vrais volumes de stockage** ainsi que des fichiers de **`/etc/pve`**.
> Il est transactionnel et effectue un rollback en cas d'échec, mais **utilisez-le à vos propres risques** :
> conservez toujours une sauvegarde fonctionnelle et testez d'abord sur un invité jetable.

## Sommaire

- [Ce que fait le script](#ce-que-fait-le-script)
- [Prérequis](#prérequis)
- [Lancement rapide](#lancement-rapide)
- [Types de stockage pris en charge](#types-de-stockage-pris-en-charge)
- [Utilisation](#utilisation)
- [Garde-fous](#garde-fous)
- [Sûreté & intégrité](#sûreté--intégrité)
- [Tests & appel à l'aide](#tests--appel-à-laide)
- [Contribuer](#contribuer)
- [Licence](#licence)

---

## Ce que fait le script

Renommer un VMID à la main, c'est éditer la configuration, renommer chaque
disque, chaque volume de snapshot/vmstate, les sauvegardes, la ressource HA, le
fichier pare-feu… et rendre **tout** cela cohérent. Ce script le fait pour vous,
en une seule passe, et annule tout automatiquement si une étape échoue.

- **Vérifications sur tout le cluster** - confirme que le VMID source existe et que le VMID cible est libre sur chaque nœud.
- **Arrêt propre** - propose et arrête la VM/CT si elle tourne.
- **Renommage de la configuration** - `/etc/pve/.../<ancien>.conf` → `<nouveau>.conf`.
- **Volumes de stockage** - LVM, ZFS, Ceph/RBD et images fichier (voir le [tableau ci-dessous](#types-de-stockage-pris-en-charge)).
- **Snapshots & vmstate** - renommés à la fois dans la configuration et sur le disque.
- **Sauvegardes & jobs** - dumps `vzdump` et entrées `jobs.cfg` / `replication.cfg` mis à jour ; les snapshots PBS sont détectés et signalés.
- **Pools & ACL** - les lignes `acl:` / `pool:` de `/etc/pve/user.cfg` sont mises à jour sur tout le cluster.
- **HA & pare-feu** - la ressource HA est désactivée pendant le renommage, son SID renommé et son état d'origine restauré ; le fichier `/etc/pve/firewall/<VMID>.fw` propre à l'invité est déplacé.
- **Transactionnel avec rollback** - la configuration d'origine reste intacte jusqu'à ce que tous les renommages réussissent ; en cas d'échec, tous les renommages sont annulés et aucune cible existante n'est écrasée.
- **Journalisation complète** - chaque action est horodatée dans la console et dans `rename-vmid.sh.log`.

---

## Prérequis

- **Proxmox VE 8.x ou plus récent** (`bash`, `pvesh`, `pvecm`, `pvesm`, `qm`, `pct`)
- **`dialog`** (le script propose de l'installer s'il manque)
- privilèges **root**

---

## Lancement rapide

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sannier3/proxmox-vmid-updater/main/rename-vmid.sh)"
```

Puis suivez les invites interactives.

---

## Types de stockage pris en charge

| Stockage | Renommé via |
| --- | --- |
| **LVM / LVM-thin** (y compris templates `base-*` et disques cloud-init) | `lvrename` |
| **ZFS** datasets & snapshots (y compris clones liés) | `zfs rename` |
| **Ceph/RBD** images bloc (y compris clusters externes) | `rbd rename` |
| **Fichier** sous `images/<VMID>/…` (local, NFS, CIFS, GlusterFS, CephFS) | `mv` |

> [!NOTE]
> Nouveau : les points de montage bind/device (LXC `mpX: /chemin/hote`) et les lecteurs
> ISO / CD-ROM vides sont détectés et **laissés intacts** automatiquement, suite à
> l'issue [#5](https://github.com/sannier3/proxmox-vmid-updater/issues/5).

---

## Utilisation

1. Passez **root** sur le nœud qui héberge l'invité.
2. Lancez la commande de [lancement rapide](#lancement-rapide) (ou `bash rename-vmid.sh`).
3. Saisissez le **VMID actuel**, puis le **nouveau VMID** lorsque demandé.
4. Confirmez l'arrêt propre et **vérifiez le récapitulatif** de tout ce qui va changer.
5. Après confirmation, le script renomme tout en une seule passe transactionnelle.

> [!TIP]
> L'écran de récapitulatif est en lecture seule - rien n'est modifié tant que vous n'avez pas confirmé « Apply ».

---

## Garde-fous

Avant de toucher à quoi que ce soit, le script **s'arrête proprement sans rien modifier** si :

- un disque ou un état sauvegardé se trouve sur un **stockage hors ligne / désactivé** ;
- l'invité est un **template qui possède encore des clones liés** ;
- un **job de réplication** existe pour l'invité ;
- l'invité est **occupé** (un verrou `lock:` dans la configuration ou une tâche
  active : sauvegarde, migration, snapshot, clone ou déplacement de disque).

Le VMID cible est par ailleurs re-vérifié libre, et l'invité re-vérifié inactif,
juste avant l'application du renommage.

---

## Sûreté & intégrité

- **Aucune connexion externe** - utilise uniquement les API Proxmox locales et les systèmes de fichiers montés.
- **Lecture seule jusqu'à confirmation** - chaque modification destructive est protégée par une confirmation.
- **Atomique & réversible** - les renommages de volumes sont suivis et annulés automatiquement si une étape échoue ; la configuration n'est validée qu'une fois tous les renommages réussis.
- **Entièrement journalisé** - toutes les actions sont écrites dans `rename-vmid.sh.log` dans le répertoire courant.

---

## Tests & appel à l'aide

Ce script touche aux volumes de stockage et à `/etc/pve` ; des tests réels sur
des configurations variées sont donc extrêmement précieux. **Si vous pouvez
aider, testez un ou plusieurs des scénarios ci-dessous sur un invité jetable**
(utilisez un VMID sans importance et assurez-vous d'avoir une sauvegarde
fonctionnelle au préalable).

Scénarios à valider :

- [ ] **LXC** avec un bind mount `mp0` (ex. `mp0: /mnt/storage,mp=/data`) - doit rester intact
- [X] **QEMU sur LVM / LVM-thin** (`local-lvm`), un seul disque simple
- [X] **QEMU sur ZFS** et **rootfs LXC sur un subvol ZFS**
- [ ] **Clone lié** (ZFS ou fichier) - seul le volume enfant est renommé
- [ ] VM avec un disque **cloud-init**
- [ ] VM avec un **snapshot + vmstate** (état RAM)
- [ ] VM avec un **pare-feu** propre à l'invité (`/etc/pve/firewall/<VMID>.fw`)
- [ ] Invité **géré en HA** - ressource désactivée pendant le renommage, état d'origine restauré ensuite
- [ ] Volume **Ceph/RBD** (cluster local, et cluster externe si vous en avez un)
- [ ] Les **garde-fous** s'arrêtent proprement : stockage hors ligne/désactivé, template avec clones liés, job de réplication existant, invité occupé/verrouillé (ex. renommage tenté pendant une sauvegarde)
- [ ] Chemin de **rollback** : provoquez un échec (ex. un volume cible déjà existant) et vérifiez que l'invité reste intact sous l'ancien VMID
- [ ] Nœud en **cluster** vs **autonome**, avec et sans quorum

> [!IMPORTANT]
> **Vous avez réalisé un ou plusieurs de ces tests ?** Aidez le projet :
> - ouvrez une **issue** avec votre résultat (succès ou échec), le type de stockage utilisé et les lignes pertinentes de `rename-vmid.sh.log` ; **ou**
> - proposez directement une **pull request** si vous avez un correctif ou une amélioration.
>
> Même un simple rapport *« scénario X testé sur stockage Y, fonctionne comme
> prévu »* est utile - il indique à tous quelles configurations sont validées
> sur le terrain.

---

## Contribuer

Les issues et pull requests sont les bienvenues :
[github.com/sannier3/proxmox-vmid-updater/issues](https://github.com/sannier3/proxmox-vmid-updater/issues)

---

## Licence

Distribué sous **GNU GPL v3**.
