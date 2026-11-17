#!/bin/bash
# demo_setup.sh - Prepara uno scenario di DIMOSTRAZIONE per CPostureStackY.
#
# ATTENZIONE: questo script NON fa parte del plugin (che è read-only).
# Serve solo a creare apposta risorse "giuste" e "sbagliate" per mostrare cosa
# rileva l'analisi. Tutte le risorse hanno il prefisso "cps-demo" così
# demo_cleanup.sh può rimuoverle senza toccare altro.
#
# PESO SUL SISTEMA (importante su una VM DevStack piccola)
#   Modalità LEGGERA (default): 2 VM, 3 volumi da 1 GB, 1 snapshot.
#   Modalità COMPLETA (CPS_DEMO_FULL=1): aggiunge un backup nativo e un volume
#   su VM spenta. Il backup coinvolge il servizio Cinder Backup (compressione e
#   scrittura su Swift) ed è la parte più pesante: attivalo solo se la VM ha
#   risorse a sufficienza (almeno 8 GB di RAM consigliati).
#   Le VM usano il flavor con meno RAM e, se esiste, un'immagine cirros.
#   Se la RAM libera è sotto CPS_DEMO_MIN_MEM_MB (default 2048) le VM NON
#   vengono create (a meno di CPS_DEMO_FORCE=1): meglio una demo parziale di
#   una VM bloccata.
#   A ogni passo lo script stampa carico e memoria libera ("[risorse]"): se la
#   macchina si blocca, l'ultima riga indica dove.
#
# SCENARIO (modalità leggera)
#  VM: vm-active (ACTIVE, usa sg-web e sg-internal), vm-stopped (SHUTOFF, sg-stopped)
#
#  Security Group                                  esito atteso
#    sg-web       22, 80, 3306 aperte a tutti,     RISCHIO ATTIVO: HIGH (22), HIGH (3306),
#                 usato da vm-active                MEDIUM (80)
#    sg-internal  22 solo dalla rete 10.0.0.0/8,   nessuna segnalazione
#                 usato da vm-active
#    sg-stopped   22 aperta a tutti,               IGIENE: LOW "[Igiene] ... solo VM non attive"
#                 usato solo da vm-stopped
#    sg-orphan    3306 aperta a tutti,             IGIENE: LOW "[Igiene] ... non associato"
#                 usato da nessuna VM
#
#  Volume                                          esito atteso
#    vol-protected  su vm-active, con snapshot     nessuna segnalazione (protetto)
#    vol-nobackup   su vm-active, nessuna copia    Backup MEDIUM
#    vol-orphan     non collegato a nessuna VM     Resource MEDIUM "Volume orfano";
#                                                   NESSUNA segnalazione di Backup
#  Solo modalità completa:
#    vol-backup     su vm-active, solo backup      nessuna segnalazione (se il servizio backup
#                   nativo                          non c'è: MEDIUM + INFO "Backup nativi")
#    vol-onstopped  su vm-stopped                  fuori perimetro backup (conteggiato "esclusi")
#
# USO A STADI E "A SECCO" (consigliati su una macchina piccola)
#   CPS_DEMO_DRYRUN=1 bash scripts/demo_setup.sh    stampa i comandi, non crea NIENTE
#   bash scripts/demo_setup.sh security             solo Security Group (solo chiamate API)
#   bash scripts/demo_setup.sh volumes              solo volumi e snapshot
#   bash scripts/demo_setup.sh vms                  solo VM, collegamenti e spegnimento
#   Si esegue uno stadio alla volta, controllando RAM e carico (es. "free -m" o
#   "top" in un secondo terminale) prima del successivo.
#   Le VM NON vengono create se manca /dev/kvm (emulazione software) o c'è una
#   sola vCPU, a meno di CPS_DEMO_FORCE=1. Alternativa senza OpenStack:
#   python scripts/demo_offline.py
#
# CINDER/LVM: prima di creare volumi, se cinder-volume non risulta "up", lo script
#   richiama scripts/fix_cinder_lvm.sh, che ripristina in modo sicuro il Volume Group
#   dopo un riavvio (loop device cambiato rispetto al filtro di /etc/lvm/lvm.conf).
#   Se Cinder è già "up" non viene fatto nulla. In modalità a secco si esegue solo
#   la diagnosi (--check-only). Per saltare il controllo: CPS_DEMO_SKIP_CINDER_FIX=1.
#
# Variabili opzionali: CPS_DEMO_SKIP_CINDER_FIX, CPS_DEMO_DRYRUN, CPS_CLOUD, CPS_DEMO_FULL, CPS_DEMO_MIN_MEM_MB, CPS_DEMO_FORCE,
#                      CPS_DEMO_IMAGE, CPS_DEMO_FLAVOR, CPS_DEMO_NETWORK
# Uso:  bash scripts/demo_setup.sh

export OS_CLOUD=${CPS_CLOUD:-devstack-admin}   # cloud di clouds.yaml
P=cps-demo                                     # prefisso di tutte le risorse
FULL=${CPS_DEMO_FULL:-0}
MIN_MEM_MB=${CPS_DEMO_MIN_MEM_MB:-2048}
DRYRUN=${CPS_DEMO_DRYRUN:-0}                   # 1 = stampa i comandi senza eseguirli
STAGE=${1:-all}                                # security | volumes | vms | all
WAIT_STEPS=30                                  # 30 tentativi x 2 s = circa 60 s

# Esegue un comando openstack che MODIFICA lo stato (create, add, stop).
# In modalità a secco (CPS_DEMO_DRYRUN=1) lo stampa soltanto: nulla viene creato.
mutate() {
    if [ "$DRYRUN" = "1" ]; then
        echo "   [a secco] openstack $*" >&2
        return 0
    fi
    openstack "$@"
}

# True se lo stadio richiesto da riga di comando comprende quello indicato.
stage_enabled() { [ "$STAGE" = "all" ] || [ "$STAGE" = "$1" ]; }

# Stampa il motivo e ritorna 0 se la macchina NON è adatta a eseguire VM di demo.
#  - senza /dev/kvm DevStack usa QEMU in emulazione software (TCG): ogni VM
#    saturerebbe la CPU e una macchina con poche vCPU diventa inutilizzabile;
#  - con una sola vCPU libvirt, nova, cinder e le VM si contendono l'unico core.
hardware_problem() {
    if [ ! -e /dev/kvm ]; then
        echo "manca /dev/kvm: le VM sarebbero EMULATE via software e saturerebbero la CPU"
        return 0
    fi
    local cpus
    cpus=$(nproc 2>/dev/null || echo 1)
    if [ "$cpus" -lt 2 ]; then
        echo "solo $cpus vCPU disponibile"
        return 0
    fi
    return 1
}

# Stampa carico medio e memoria disponibile: serve a capire dove la macchina
# va in sofferenza. Se /proc non esiste (non Linux) non stampa nulla.
show_load() {
    [ -r /proc/meminfo ] || return 0
    echo "   [risorse] $1 | load: $(cut -d' ' -f1-3 /proc/loadavg) | RAM libera: $(available_mb) MB"
}

# Memoria disponibile in MB (vuoto se non determinabile)
available_mb() {
    awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null
}

# Attende che una risorsa raggiunga lo stato voluto (max circa 60 secondi).
# Uso: wait_status <comando-show...> <stato-atteso>
#   es. wait_status volume show cps-demo-vol available
# Ritorna 0 se raggiunto, 1 se la risorsa va in errore o scade il tempo.
wait_status() {
    [ "$DRYRUN" = "1" ] && return 0
    local expected="${*: -1}"
    local show_cmd=("${@:1:$#-1}")
    local current
    for _ in $(seq 1 "$WAIT_STEPS"); do
        current=$(openstack "${show_cmd[@]}" -f value -c status 2>/dev/null)
        [ "${current,,}" = "${expected,,}" ] && return 0
        [ "${current,,}" = "error" ] && return 1
        sleep 2
    done
    return 1
}

# Crea un volume da 1 GB e attende che sia pronto. Ritorna 1 se non utilizzabile.
create_volume() {
    mutate volume create --size 1 "$1" > /dev/null || return 1
    wait_status volume show "$1" available
}

# Collega un volume a una VM e attende lo stato "in-use".
attach_volume() {   # $1 = VM, $2 = volume
    mutate server add volume "$1" "$2" \
        && wait_status volume show "$2" in-use \
        || echo "ATTENZIONE: volume $2 non collegato a $1"
}

# Flavor con la RAM minore. Si leggono ESPLICITAMENTE Name e RAM e si ordina per
# RAM numerica (--sort-column con una colonna non mostrata viene ignorato).
# L'awk riconosce la colonna numerica, così non dipende dall'ordine di stampa.
smallest_flavor() {
    openstack flavor list -f value -c Name -c RAM 2>/dev/null | awk '
        NF >= 2 { if ($1 ~ /^[0-9]+$/) print $1, $2; else print $2, $1 }' \
        | sort -n | head -n 1 | cut -d' ' -f2
}

# Immagine: preferisce cirros (pochi MB); altrimenti la prima, con un avviso.
pick_image() {
    local images cirros
    images=$(openstack image list -f value -c Name 2>/dev/null)
    cirros=$(echo "$images" | grep -i -m 1 cirros)
    if [ -n "$cirros" ]; then
        echo "$cirros"
    else
        echo "ATTENZIONE: nessuna immagine cirros: uso la prima disponibile" >&2
        echo "$images" | head -n 1
    fi
}

# Garantisce che Cinder/LVM sia utilizzabile PRIMA di creare qualunque risorsa.
# Serve solo agli stadi che usano Cinder (volumes, vms: i collegamenti dei volumi).
# Con cinder-volume già "up" non fa nulla (e non richiede privilegi di root).
ensure_cinder_ready() {
    stage_enabled volumes || stage_enabled vms || return 0
    if [ "${CPS_DEMO_SKIP_CINDER_FIX:-0}" = "1" ]; then
        echo "   (controllo Cinder/LVM saltato: CPS_DEMO_SKIP_CINDER_FIX=1)"
        return 0
    fi
    local state fix_script code options=()
    state=$(openstack volume service list --service cinder-volume -f value -c State \
            </dev/null 2>/dev/null | head -n 1)
    if [ "$state" = "up" ]; then
        echo "   Cinder operativo (cinder-volume: up): nessun intervento necessario."
        return 0
    fi
    fix_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix_cinder_lvm.sh"
    if [ ! -f "$fix_script" ]; then
        echo "ATTENZIONE: cinder-volume non è 'up' (stato: ${state:-sconosciuto}) e $fix_script non esiste."
        return 0
    fi
    [ "$DRYRUN" = "1" ] && options=(--check-only)
    echo "== 0) cinder-volume non è 'up' (stato: ${state:-sconosciuto}): controllo Cinder/LVM"
    bash "$fix_script" "${options[@]}"
    code=$?
    case "$code" in
        0)  return 0 ;;
        10) echo "   Cinder non usa il back-end LVM di DevStack: controllo non applicabile, proseguo." ;;
        20) echo "   (a secco) servirebbe una correzione: nessuna modifica effettuata." ;;
        *)  echo "ERRORE: Cinder/LVM non è pronto (codice $code): non creo nessuna risorsa."
            echo "        Risolvi con le istruzioni sopra, oppure salta il controllo con CPS_DEMO_SKIP_CINDER_FIX=1."
            exit 1 ;;
    esac
}

# Evita di creare duplicati: i nomi delle risorse devono essere univoci.
case "$STAGE" in
    all|security|volumes|vms) ;;
    *) echo "Uso: bash scripts/demo_setup.sh [security|volumes|vms]   (senza argomento: tutto)"; exit 2 ;;
esac
if stage_enabled security \
        && openstack security group list -f value -c Name 2>/dev/null | grep -q "^$P-"; then
    echo "Esistono già risorse $P-*: esegui prima  bash scripts/demo_cleanup.sh"
    exit 1
fi
ensure_cinder_ready
echo "Modalità: $([ "$FULL" = "1" ] && echo COMPLETA || echo LEGGERA) | stadio: $STAGE$([ "$DRYRUN" = "1" ] && echo " | A SECCO (nulla viene creato)")"
show_load "inizio"

echo "== 1) Security Group (rischio attivo, igiene, controllo negativo)"
if stage_enabled security; then
for sg in sg-web sg-internal sg-stopped sg-orphan; do
    mutate security group create "$P-$sg" --description "Demo CPostureStackY" > /dev/null
done
for port in 22 80 3306; do
    mutate security group rule create --protocol tcp --dst-port "$port" \
        --remote-ip 0.0.0.0/0 "$P-sg-web" > /dev/null
done
mutate security group rule create --protocol tcp --dst-port 22 \
    --remote-ip 10.0.0.0/8 "$P-sg-internal" > /dev/null
mutate security group rule create --protocol tcp --dst-port 22 \
    --remote-ip 0.0.0.0/0 "$P-sg-stopped" > /dev/null
mutate security group rule create --protocol tcp --dst-port 3306 \
    --remote-ip 0.0.0.0/0 "$P-sg-orphan" > /dev/null
show_load "security group creati"
fi

echo "== 2) Volumi (le copie di protezione si creano PRIMA del collegamento)"
if stage_enabled volumes; then
VOLUMES="vol-protected vol-nobackup vol-orphan"
[ "$FULL" = "1" ] && VOLUMES="$VOLUMES vol-backup vol-onstopped"
for vol in $VOLUMES; do
    create_volume "$P-$vol" || echo "ATTENZIONE: $P-$vol non pronto: Cinder non funziona?"
done
show_load "volumi creati"

# Snapshot e backup di un volume "in-use" richiedono --force: creandoli quando il
# volume è ancora 'available' si evita il problema.
mutate volume snapshot create --volume "$P-vol-protected" "$P-snap" > /dev/null \
    && wait_status volume snapshot show "$P-snap" available \
    || echo "ATTENZIONE: snapshot di vol-protected non creato"
show_load "snapshot creato"

if [ "$FULL" = "1" ]; then
    echo "   (modalità completa) backup nativo: operazione pesante, attendo..."
    if mutate volume backup create --name "$P-backup" "$P-vol-backup" > /dev/null 2>&1 \
            && wait_status volume backup show "$P-backup" available; then
        echo "   backup nativo creato"
    else
        echo "ATTENZIONE: backup nativo non disponibile (servizio Cinder Backup/Swift?):"
        echo "            vol-backup sarà segnalato come non protetto, con INFO 'Backup nativi'."
    fi
    show_load "backup completato"
fi
fi

echo "== 3) VM: una attiva e una da spegnere (flavor più piccolo)"
if stage_enabled vms; then
IMAGE=${CPS_DEMO_IMAGE:-$(pick_image)}
NET=${CPS_DEMO_NETWORK:-$(openstack network list --internal -f value -c Name | head -n 1)}
FLAVOR=${CPS_DEMO_FLAVOR:-$(smallest_flavor)}
VMS_READY=0
FREE_MB=$(available_mb)
if [ -z "$IMAGE" ] || [ -z "$NET" ] || [ -z "$FLAVOR" ]; then
    echo "   immagine, rete o flavor non trovati: salto la creazione delle VM"
elif HW_REASON=$(hardware_problem) && [ "${CPS_DEMO_FORCE:-0}" != "1" ]; then
    echo "   NON creo le VM: $HW_REASON."
    echo "   (usa CPS_DEMO_FORCE=1 a tuo rischio, oppure la demo offline: python scripts/demo_offline.py)"
elif [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt "$MIN_MEM_MB" ] && [ "${CPS_DEMO_FORCE:-0}" != "1" ]; then
    echo "   RAM libera ${FREE_MB} MB < ${MIN_MEM_MB} MB: NON creo le VM per non bloccare la macchina."
    echo "   (libera memoria oppure usa CPS_DEMO_FORCE=1 a tuo rischio)"
else
    echo "   immagine=$IMAGE rete=$NET flavor=$FLAVOR"
    if mutate server create --flavor "$FLAVOR" --image "$IMAGE" --network "$NET" \
            --security-group "$P-sg-web" --security-group "$P-sg-internal" \
            --wait "$P-vm-active" > /dev/null; then
        show_load "vm-active avviata"
        if mutate server create --flavor "$FLAVOR" --image "$IMAGE" --network "$NET" \
                --security-group "$P-sg-stopped" --wait "$P-vm-stopped" > /dev/null; then
            show_load "vm-stopped avviata"
            VMS_READY=1
        fi
    fi
    [ "$VMS_READY" = "1" ] || echo "ATTENZIONE: creazione delle VM non riuscita: salto i collegamenti dei volumi"
fi

echo "== 4) Collegamento dei volumi alle VM"
if [ "$VMS_READY" = "1" ]; then
    attach_volume "$P-vm-active" "$P-vol-protected"
    attach_volume "$P-vm-active" "$P-vol-nobackup"
    if [ "$FULL" = "1" ]; then
        attach_volume "$P-vm-active" "$P-vol-backup"
        attach_volume "$P-vm-stopped" "$P-vol-onstopped"   # prima dello spegnimento
    fi
    show_load "volumi collegati"
    mutate server stop "$P-vm-stopped" \
        && wait_status server show "$P-vm-stopped" SHUTOFF \
        || echo "ATTENZIONE: la VM $P-vm-stopped non risulta spenta"
    show_load "vm-stopped spenta"
fi
fi

echo
echo "Scenario pronto. Ora lancia:  python -m cpostureStacky.main"
echo "Risultati attesi: vedi l'elenco in testa a questo file e nel README."
