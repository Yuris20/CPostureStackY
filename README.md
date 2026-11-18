# CPostureStackY - Cloud Security & Health Assessment Plugin per OpenStack

## Abstract
CPostureStackY è un plugin DevStack scritto in Python che, al termine del
deployment, analizza in **sola lettura** lo stato dell'infrastruttura OpenStack
tramite `openstacksdk` e genera un report HTML. L'analisi è **workload-centric**:
dà priorità a ciò che impatta le VM in esecuzione e tiene separata la semplice
"igiene" della configurazione.

| Area | Servizio | Cosa controlla |
|------|----------|----------------|
| Security | Nova + Neutron | Regole dei Security Group aperte a 0.0.0.0/0 o ::/0. Gravità piena se il gruppo protegge una VM attiva; solo LOW ("igiene") se è orfano o usato solo da VM non attive |
| System | Nova | Stato delle VM (ERROR, SHUTOFF, PAUSED, stati transitori, incoerenze di power state) |
| Resource | Nova / Cinder | Utilizzo RAM e vCPU, volumi orfani o in errore |
| Backup | Nova + Cinder | Protezione dei volumi collegati a VM attive: almeno uno snapshot o un backup nativo recente e valido |

Nessun database, framework web o sistema di monitoraggio esterno: solo Python
standard + `openstacksdk`.

## Perimetro: che cos'è una "VM attiva"
Un'unica definizione, in `checks/common.py`, usata da Security e Backup:
una VM è **attiva** se Nova la riporta in stato `ACTIVE`. VM spente, in errore o in
pausa non contano come workload in esecuzione.

### Security Group: rischio attivo e igiene
Nova indica nei server solo i *nomi* dei Security Group (ambigui tra progetti),
quindi l'associazione si ricava dalle porte Neutron: `server (Nova)` →
`device_id` della porta (Neutron) → `security_group_ids`.

| Situazione del gruppo | Segnalazione |
|-----------------------|--------------|
| Associato ad almeno una VM **attiva**, regola aperta a tutti | HIGH (tutte le porte, tutto il traffico, porta sensibile 22/3389/3306/5432), MEDIUM (altre porte), LOW (ICMP). Il messaggio elenca le VM coinvolte |
| Non associato ad alcuna VM, oppure solo a VM non attive | sempre **LOW** con prefisso `[Igiene]`: configurazione residua, oggi non espone nulla |

Con `CPS_REPORT_UNUSED_SG=0` i gruppi non usati non vengono segnalati affatto
(report puramente sui workload). Si valutano solo le regole in ingresso; non si
verifica se la VM sia davvero raggiungibile da Internet (es. floating IP).

### Backup: solo volumi in uso
- **In perimetro**: volumi con un attachment verso una VM attiva.
- **Fuori perimetro**: volumi orfani (lo spreco è segnalato da `resource.py`, non si
  duplica la segnalazione come "senza backup") e volumi collegati solo a VM non attive.
  Il riepilogo INFO del report dichiara quanti volumi sono stati esclusi.
- **Protetto** = almeno uno snapshot **oppure** un backup nativo (`block_storage.backups`,
  verso Swift/Object Storage) in stato `available` e non più vecchio di
  `CPS_BACKUP_MAX_AGE_DAYS` giorni (conta il più recente dei due).
- Gravità: MEDIUM se non c'è nulla di valido o se l'ultima copia è oltre la soglia;
  HIGH oltre il doppio della soglia; LOW se la copia è ancora in creazione o è in errore.
- Se il servizio backup non risponde il controllo prosegue con i soli snapshot e lo
  dichiara con un INFO ("Backup nativi").

Nota: uno snapshot resta sullo stesso storage del volume; il backup nativo no.
Il plugin li considera entrambi sufficienti, come richiesto, ma non distingue la
robustezza della protezione.

## Errori dei controlli
Se un controllo non riesce a completarsi (servizio non raggiungibile, credenziali
errate...) il report **non** mostra "OK": il riquadro della categoria diventa
**ERRORE** e il programma esce con codice 2. Codici di uscita: `0` analisi
completa (anche se trova problemi), `1` connessione non riuscita, `2` report
generato ma parziale.

## Architettura
```
            DevStack (stack.sh)
                   |  fase "extra" (deployment concluso)
                   v
          devstack/plugin.sh
                   |
                   v
            cpostureStacky/main.py        <- solo coordinamento
                   |
   +---------------+----------------+-----------------+
   v               v                v                 v
checks/security  checks/system  checks/resource  checks/backup
(Nova+Neutron)     (Nova)       (Nova+Cinder)    (Nova+Cinder)
   |               |                |                 |
   +--- checks/common.py (perimetro "VM attiva", date) ---+
                            | lista di "finding" (findings.py)
                            v
                   cpostureStacky/report.py  ->  reports/report_<data>.html
```

- Ogni check espone `CATEGORY` e `run(conn, config) -> list[dict]` e gestisce da solo i propri errori.
- `findings.py` definisce il formato unico del finding
  `{"category", "severity" (HIGH|MEDIUM|LOW|INFO), "resource", "message"}`
  e lo valida alla creazione.
- `connection.py` crea la connessione leggendo `clouds.yaml` (nessuna credenziale nel codice).
- `config.py` raccoglie soglie e percorsi, sovrascrivibili con variabili `CPS_*`:
  è l'unica fonte dei valori di default.
- **READ-ONLY per costruzione**: il codice usa solo chiamate `list`/`get` dell'SDK.
- Report: tutti i testi provenienti da OpenStack passano da `html.escape()`; il file è
  scritto con permessi `0600`.

## Struttura del repository
```
devstack/plugin.sh, devstack/settings   integrazione DevStack
cpostureStacky/main.py                  coordinamento
cpostureStacky/findings.py              formato e costruttori dei finding
cpostureStacky/connection.py            connessione openstacksdk
cpostureStacky/config.py                soglie, opzioni e percorsi
cpostureStacky/checks/                  security.py, system.py, resource.py, backup.py, common.py
cpostureStacky/report.py                report HTML (con filtri) e riepilogo console
scripts/                                demo_setup.sh, demo_cleanup.sh, fix_cinder_lvm.sh, systemd/ (non fanno parte del plugin)
reports/                                report generati
```

## Uso manuale
```
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m cpostureStacky.main
```
Il report viene salvato in `reports/report_<data>_<ora>.html`. Il report ha filtri
interattivi per severità, categoria e risorsa.

## Uso come plugin DevStack
Nel `local.conf`:
```
[[local|localrc]]
enable_plugin cpostureStacky https://github.com/Yuris20/CPostureStackY
enable_service cpostureStacky
```
Poi `./stack.sh`. L'analisi parte nella fase `extra`; se fallisce o è parziale, il
deployment non viene interrotto. Il report si trova in `$DEST/cpostureStacky/reports/`.

## Configurazione (variabili d'ambiente)
| Variabile | Default | Significato |
|-----------|---------|-------------|
| `CPS_CLOUD` | `devstack-admin` | cloud in clouds.yaml |
| `CPS_REPORTS_DIR` | `<repo>/reports` | cartella dei report |
| `CPS_BACKUP_MAX_AGE_DAYS` | 7 | età massima dell'ultimo snapshot/backup (il vecchio nome `CPS_SNAPSHOT_MAX_AGE_DAYS` è ancora accettato) |
| `CPS_REPORT_UNUSED_SG` | 1 | `0` = ignora i Security Group non usati da VM attive |
| `CPS_RAM_WARN` / `CPS_VCPU_WARN` | 80 | soglia di avviso (%) |
| `CPS_USAGE_CRIT` | 95 | soglia critica (%) |
| `CPS_LOG_LEVEL` | `WARNING` | livello dei log diagnostici (`DEBUG` mostra i dettagli degli errori) |

## Limiti noti
- **Capacità**: dalla microversion 2.88 di Nova l'API degli hypervisor non espone più
  RAM/vCPU. In quel caso si usano le quote del progetto dell'utente (limite amministrativo
  di un solo progetto, non capacità fisica) e il report lo dichiara con un INFO.
- Le credenziali devono essere amministrative (`all_projects`): con un utente normale
  si vedrebbero solo le risorse del proprio progetto.
- I volumi sono "orfani" se `available` e senza attachment.
- La mappatura Security Group → VM considera solo le porte Neutron di VM Nova; gruppi usati
  solo da altre porte (router, load balancer) risultano "non associati ad alcuna VM".
- Una regola senza `remote_ip_prefix` né `remote_group_id` è trattata come aperta a tutti
  (semantica Neutron): comportamento da confermare sul proprio cloud.
- Nessuna analisi dei ruoli/permessi Keystone né dei Floating IP (estensioni future).

## Cinder/LVM dopo un riavvio (`scripts/fix_cinder_lvm.sh`)
**Problema.** DevStack salva i dati di Cinder in un file (*backing file*) collegato a un
loop device e scrive in `/etc/lvm/lvm.conf` un filtro che accetta solo quel loop, ad es.
`global_filter = [ "a|loop19|", "r|.*|" ]`. Dopo un riavvio il file può tornare collegato a
un altro loop (es. `/dev/loop21`): LVM ignora il disco giusto, il Volume Group
`stack-volumes-lvmdriver-1` sparisce e `cinder-volume` resta *down*.

**Soluzione.** Lo script individua il loop con `losetup -j <backing file>` (confronta il
**file**, mai un numero fisso), verifica la firma `LVM2_member`, capisce *perché* LVM non
vede il disco e interviene solo se la causa è dimostrata:

| Situazione rilevata | Azione |
|---|---|
| VG visibile e Cinder `up` | nessuna (esce con 0, nulla viene modificato) |
| VG visibile, LV inattivi o Cinder `down` | `vgchange -ay` e/o riavvio del servizio, senza toccare la configurazione |
| Dispositivo respinto da `global_filter`/`filter` | aggiunge `a|^/dev/loopN$|` **prima** della regola che lo respinge; le altre regole restano invariate |
| `use_devicesfile=1` e dispositivo non elencato | `lvmdevices --adddev` (con backup di `system.devices`) |
| Cache LVM non aggiornata | `pvscan --cache` |
| Backing file assente, loop non collegato, più loop sullo stesso file, firma LVM assente, PV senza VG, VG parziale, causa non riconosciuta | **si ferma** con un codice di uscita e istruzioni diagnostiche; non modifica nulla |

**Sicurezza.** Non esegue mai `pvcreate`, `vgcreate`, `mkfs`, `wipefs` né `vgcfgrestore`;
non ricrea il VG; non elimina dati. Prima di modificare `lvm.conf` crea un backup datato
(`lvm.conf.cps-bak-AAAAMMGG-HHMMSS`), ne verifica l'identità, valida il nuovo file con
`lvmconfig` in una cartella temporanea e lo installa in modo atomico. Se dopo la modifica il
VG non è visibile, ripristina automaticamente il backup. Cinder viene riavviato **solo** a
VG visibile e volumi attivi. È idempotente (nessuna regola o backup duplicati).

```
bash scripts/fix_cinder_lvm.sh --check-only   # solo diagnosi: mostra cosa farebbe (codice 20 se serve una correzione)
bash scripts/fix_cinder_lvm.sh                # applica la correzione se necessaria
bash scripts/fix_cinder_lvm.sh --attach-loop  # se il file non è collegato a nessun loop, lo collega (losetup -f --show)
bash scripts/fix_cinder_lvm.sh --no-restart   # non riavvia Cinder
```
Codici di uscita: `0` ok · `10` Cinder/LVM di DevStack non applicabile · `11` loop non collegato ·
`12` più loop · `13` nessuna firma LVM · `14` PV senza VG / VG parziale / altro VG ·
`15` correzione impossibile o inefficace (configurazione ripristinata) · `16` Cinder non torna `up` ·
`17` requisiti mancanti · `20` (solo `--check-only`) serve una correzione.
Variabili: `CPS_CINDER_VG`, `CPS_CINDER_BACKING_FILE`, `CPS_CINDER_SERVICE`, `CPS_LVM_CONF`,
`CPS_LVM_DEVICES_FILE`, `CPS_CINDER_WAIT`.

**Integrazione.** Non è nel plugin DevStack (`devstack/plugin.sh` gira dopo l'avvio dei servizi
ed è un'analisi in sola lettura). Lo richiamano gli script demo, ma **solo se `cinder-volume`
non risulta `up`**: `demo_setup.sh` prima di creare qualsiasi risorsa (stadi `volumes` e `vms`;
se il ripristino fallisce non crea nulla) e `demo_cleanup.sh` prima di cancellare (se fallisce
prosegue con un avviso). In modalità a secco usano `--check-only`. Per saltare il controllo:
`CPS_DEMO_SKIP_CINDER_FIX=1`. Per renderlo automatico a ogni avvio esiste una unit systemd
**facoltativa e non installata** in `scripts/systemd/`.

**Limiti.** Richiede root (usa `sudo` se non lo si è). Non provato su una VM DevStack
reale: i messaggi di LVM e il comportamento del devices file possono variare con la versione. I vecchi accept
(`a|loop19|`) restano nel filtro: sono innocui e non si possono distinguere con certezza da
regole di altri backend.

## Dimostrazione (scenario di prova)
Gli script in `scripts/` NON fanno parte del plugin (che resta read-only): servono
solo a creare risorse "sbagliate" (e alcune "giuste" come controllo) per mostrare cosa
rileva l'analisi.
```
bash scripts/demo_setup.sh      # crea la demo completa (risorse con prefisso cps-demo)
python -m cpostureStacky.main   # esegue l'analisi e crea il report
bash scripts/demo_cleanup.sh    # rimuove SOLO le risorse cps-demo-*
```

### Peso sul sistema e uso sicuro (importante su una VM DevStack piccola)
Gli script chiamano solo le API, ma il lavoro pesante lo fanno i servizi DevStack sulla
stessa macchina: avviare VM, collegare volumi e cancellare volumi (Cinder su LVM li
azzera con `dd`) può saturare CPU, RAM o disco di una VM piccola fino a renderla
inutilizzabile. Per questo:

1. **Prima simula**: `CPS_DEMO_DRYRUN=1 bash scripts/demo_setup.sh` stampa i comandi senza
   eseguirli (idem per `demo_cleanup.sh`, che mostra cosa cancellerebbe).
2. **Procedi a stadi**, controllando RAM e carico (`free -m`, `top` in un secondo
   terminale) tra uno e l'altro:
   `bash scripts/demo_setup.sh security` (solo chiamate API) →
   `... volumes` (volumi e snapshot) → `... vms` (VM, collegamenti, spegnimento).
3. **Controlli automatici**: le VM non vengono create se manca `/dev/kvm` (DevStack usa
   allora l'emulazione software e ogni VM satura la CPU), se c'è una sola vCPU o se la RAM
   libera è sotto `CPS_DEMO_MIN_MEM_MB` (default 2048). `CPS_DEMO_FORCE=1` li ignora, a
   proprio rischio.
4. **Demo completa (unica)**: 2 VM con il flavor a RAM minore e immagine cirros,
   5 volumi da 1 GB, 1 snapshot, 1 backup nativo (Cinder Backup: compressione e scrittura
   su Swift, la parte più pesante) e un volume su VM spenta: si consigliano almeno 8 GB di RAM.
5. Durante il setup ogni passo stampa `[risorse]` con carico e RAM libera.
6. Il cleanup cancella **una risorsa alla volta** attendendo ciascuna cancellazione e usa
   `--force` solo per volumi in `error_deleting`.

Variabili opzionali: `CPS_DEMO_DRYRUN`, `CPS_DEMO_MIN_MEM_MB`,
`CPS_DEMO_FORCE`, `CPS_DEMO_IMAGE`, `CPS_DEMO_FLAVOR`, `CPS_DEMO_NETWORK`.

### Risultato atteso
VM: `vm-active` ACTIVE con sg-web + sg-internal, `vm-stopped` SHUTOFF.

| Risorsa di demo | Categoria | Esito atteso |
|-----------------|-----------|--------------|
| `sg-web` (22, 80, 3306 aperte; su vm-active) | Security | HIGH (22), HIGH (3306), MEDIUM (80), con `vm-active` nel messaggio |
| `sg-internal` (22 solo da 10.0.0.0/8; su vm-active) | Security | nessuna segnalazione |
| `sg-stopped` (22 aperta; solo su vm-stopped) | Security | LOW `[Igiene]` "solo a VM non attive" |
| `sg-orphan` (3306 aperta; su nessuna VM) | Security | LOW `[Igiene]` "non associato ad alcuna VM" |
| `vm-stopped` | System | LOW (SHUTOFF) |
| `vol-nobackup` (su vm-active, nessuna copia) | Backup | MEDIUM |
| `vol-protected` (su vm-active, con snapshot) | Backup | nessuna segnalazione |
| `vol-orphan` (non collegato) | Resource | MEDIUM "Volume orfano"; **nessuna** segnalazione Backup |
| `vol-backup` (solo backup nativo) | Backup | nessuna segnalazione (MEDIUM + INFO "Backup nativi" se il servizio backup non è disponibile) |
| `vol-onstopped` (su vm-stopped) | - | fuori perimetro backup, conteggiato tra gli "esclusi" |

Per vedere anche il caso "snapshot vecchio" si può abbassare la soglia, ad esempio
`CPS_BACKUP_MAX_AGE_DAYS=0` (ogni copia è più vecchia di 0 giorni).
Nel report compariranno anche i riepiloghi INFO (VM totali, Security Group totali,
Volumi analizzati). Eventuali altri Security Group del cloud (es. `default`) sono
analizzati con le stesse regole.
