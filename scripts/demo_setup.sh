#!/bin/bash
# demo_setup.sh - Prepara uno scenario di DIMOSTRAZIONE per CPostureStackY.
#
# ATTENZIONE: questo script NON fa parte del plugin (che è read-only).
# Serve solo a creare apposta risorse "giuste" e "sbagliate" per mostrare cosa
# rileva l'analisi. Tutte le risorse hanno il prefisso "cps-demo" così
# demo_cleanup.sh può rimuoverle senza toccare altro.
#
# SCENARIO
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
#    vol-backup     su vm-active, solo backup      nessuna segnalazione (se il servizio backup
#                   nativo                          non c'è: MEDIUM + INFO "Backup nativi")
#    vol-onstopped  su vm-stopped                  fuori perimetro backup (conteggiato "esclusi")
#
# CINDER/LVM: prima di creare volumi, se cinder-volume non risulta "up", lo script
#   richiama scripts/fix_cinder_lvm.sh, che ripristina in modo sicuro il Volume Group
#   dopo un riavvio (loop device cambiato rispetto al filtro di /etc/lvm/lvm.conf).
#   Se Cinder è già "up" non viene fatto nulla. In modalità a secco si esegue solo
#   la diagnosi (--check-only). Per saltare il controllo: CPS_DEMO_SKIP_CINDER_FIX=1.
#
# Variabili opzionali: CPS_DEMO_SKIP_CINDER_FIX, CPS_DEMO_DRYRUN, CPS_CLOUD, CPS_DEMO_FORCE,
#                      CPS_DEMO_IMAGE, CPS_DEMO_FLAVOR, CPS_DEMO_NETWORK
# Uso:  bash scripts/demo_setup.sh

export OS_CLOUD=${CPS_CLOUD:-devstack-admin}
P=cps-demo
DRYRUN=${CPS_DEMO_DRYRUN:-0}
STAGE=${1:-all}
WAIT_STEPS=30

# Esegue un comando openstack che MODIFICA lo stato (create, add, stop).
mutate() {
    [ "$DRYRUN" = "1" ] && { echo "   [a secco] openstack $*" >&2; return 0; }
    openstack "$@"
}

# True se lo stadio richiesto da riga di comando comprende quello indicato.
stage_enabled() { [ "$STAGE" = "all" ] || [ "$STAGE" = "$1" ]; }

# Stampa il motivo e ritorna 0 se la macchina NON è adatta a eseguire VM di demo.
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

# Attende che una risorsa raggiunga lo stato voluto (max circa 60 secondi).
wait_status() {
    [ "$DRYRUN" = "1" ] && return 0
    local expected="${*: -1}" show_cmd=("${@:1:$#-1}") current
    for _ in $(seq 1 "$WAIT_STEPS"); do
        current=$(openstack "${show_cmd[@]}" -f value -c status 2>/dev/null)
        [ "${current,,}" = "${expected,,}" ] && return 0
        [ "${current,,}" = "error" ] && return 1
        sleep 2
    done
    return 1
}

# Crea un volume da 1 GB e attende che sia pronto.
create_volume() {
    echo "   creazione volume $1..."
    mutate volume create --size 1 "$1" > /dev/null || return 1
    wait_status volume show "$1" available
}

# Collega un volume a una VM e attende lo stato "in-use".
attach_volume() {
    echo "   collegamento volume $2 a $1..."
    mutate server add volume "$1" "$2" && wait_status volume show "$2" in-use || echo "ATTENZIONE: volume $2 non collegato a $1"
}

# Flavor con la RAM minore.
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
ensure_cinder_ready() {
    stage_enabled volumes || stage_enabled vms || return 0
    [ "${CPS_DEMO_SKIP_CINDER_FIX:-0}" = "1" ] && return 0
    [ "$(openstack volume service list --service cinder-volume -f value -c State </dev/null 2>/dev/null | head -n 1)" = "up" ] && return 0
    local fix_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix_cinder_lvm.sh"
    [ ! -f "$fix_script" ] && return 0
    local options=(); [ "$DRYRUN" = "1" ] && options=(--check-only)
    echo "== Cinder/LVM non pronto: eseguo correzione =="
    bash "$fix_script" "${options[@]}"
    local code=$?
    case "$code" in
        0|10|20) return 0 ;;
        *) exit 1 ;;
    esac
}

case "$STAGE" in
    all|security|volumes|vms) ;;
    *) echo "Uso: bash scripts/demo_setup.sh [security|volumes|vms]"; exit 2 ;;
esac

if stage_enabled security && openstack security group list -f value -c Name 2>/dev/null | grep -q "^$P-"; then
    echo "Esistono già risorse $P-*: esegui prima bash scripts/demo_cleanup.sh"
    exit 1
fi

ensure_cinder_ready

# == 1) Security Group ==
if stage_enabled security; then
    echo "== 1) Creazione Security Group in corso..."
    for sg in sg-web sg-internal sg-stopped sg-orphan; do
        mutate security group create "$P-$sg" --description "Demo CPostureStackY" > /dev/null
    done
    for port in 22 80 3306; do
        mutate security group rule create --protocol tcp --dst-port "$port" --remote-ip 0.0.0.0/0 "$P-sg-web" > /dev/null
    done
    mutate security group rule create --protocol tcp --dst-port 22 --remote-ip 10.0.0.0/8 "$P-sg-internal" > /dev/null
    mutate security group rule create --protocol tcp --dst-port 22 --remote-ip 0.0.0.0/0 "$P-sg-stopped" > /dev/null
    mutate security group rule create --protocol tcp --dst-port 3306 --remote-ip 0.0.0.0/0 "$P-sg-orphan" > /dev/null
    echo "   Security Group creati con successo."
fi

# == 2) Volumi ==
if stage_enabled volumes; then
    echo "== 2) Creazione Volumi in corso..."
    for vol in vol-protected vol-nobackup vol-orphan vol-backup vol-onstopped; do
        create_volume "$P-$vol"
    done
    echo "   Creazione snapshot per vol-protected..."
    mutate volume snapshot create --volume "$P-vol-protected" "$P-snap" > /dev/null && wait_status volume snapshot show "$P-snap" available
    echo "   Creazione backup nativo per vol-backup..."
    mutate volume backup create --name "$P-backup" "$P-vol-backup" > /dev/null 2>&1 && wait_status volume backup show "$P-backup" available
    echo "   Volumi e copie completati."
fi

# == 3) VM e Collegamenti ==
if stage_enabled vms; then
    echo "== 3) Creazione VM in corso..."
    IMAGE=${CPS_DEMO_IMAGE:-$(pick_image)}
    NET=${CPS_DEMO_NETWORK:-$(openstack network list --internal -f value -c Name | head -n 1)}
    FLAVOR=${CPS_DEMO_FLAVOR:-$(smallest_flavor)}
    VMS_READY=0

    if [ -z "$IMAGE" ] || [ -z "$NET" ] || [ -z "$FLAVOR" ]; then
        echo "   Immagine, rete o flavor non trovati: salto la creazione delle VM"
    elif HW_REASON=$(hardware_problem) && [ "${CPS_DEMO_FORCE:-0}" != "1" ]; then
        echo "   NON creo le VM: $HW_REASON."
        echo "   (usa CPS_DEMO_FORCE=1 a tuo rischio)"
    else
        echo "   Avvio $P-vm-active..."
        if mutate server create --flavor "$FLAVOR" --image "$IMAGE" --network "$NET" --security-group "$P-sg-web" --security-group "$P-sg-internal" --wait "$P-vm-active" > /dev/null; then
            echo "   Avvio $P-vm-stopped..."
            if mutate server create --flavor "$FLAVOR" --image "$IMAGE" --network "$NET" --security-group "$P-sg-stopped" --wait "$P-vm-stopped" > /dev/null; then
                VMS_READY=1
            fi
        fi
    fi

    if [ "$VMS_READY" = "1" ]; then
        echo "== 4) Collegamento volumi alle VM..."
        attach_volume "$P-vm-active" "$P-vol-protected"
        attach_volume "$P-vm-active" "$P-vol-nobackup"
        attach_volume "$P-vm-active" "$P-vol-backup"
        attach_volume "$P-vm-stopped" "$P-vol-onstopped"
        echo "   Spegnimento di $P-vm-stopped..."
        mutate server stop "$P-vm-stopped" && wait_status server show "$P-vm-stopped" SHUTOFF
    fi
fi

echo -e "\n[OK] Scenario OpenStack pronto."

# --- Esecuzione automatica ambiente Python e applicazione ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || { echo "ERRORE: Impossibile accedere alla cartella del progetto"; exit 1; }

echo "== Configurazione ambiente Python =="
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip --quiet
pip install -r requirements.txt

echo "== Avvio CPostureStackY =="
python -m cpostureStacky.main
