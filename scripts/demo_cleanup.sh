#!/bin/bash
# demo_cleanup.sh - Rimuove le risorse create da demo_setup.sh.
#
# Cancella SOLO risorse il cui nome inizia per "cps-demo-" (tutti i progetti).
# Non tocca nient'altro: nessun altro prefisso, nessuna risorsa senza nome.
# Se una cancellazione fallisce lo dice chiaramente e esce con errore.
#
# ORDINE: VM -> backup -> snapshot -> volumi -> security group. Le risorse si
# cancellano dalla più "dipendente" alla meno: un volume non si cancella se ha
# snapshot, un security group non si cancella se è usato da una VM.
#
# CARICO SUL SISTEMA (perché le cancellazioni sono SERIALIZZATE)
#   Le cancellazioni di Cinder sono asincrone e, con il back-end LVM di DevStack,
#   cancellare un volume lo AZZERA con 'dd' (volume_clear=zero): molti volumi in
#   parallelo saturano il disco di una VM piccola. Qui si cancella UNA risorsa
#   alla volta e si attende che sparisca prima di passare alla successiva.
#   Un volume ancora 'in-use'/'detaching' (la VM è appena stata cancellata) viene
#   atteso prima della cancellazione; --force si usa SOLO per lo stato
#   'error_deleting', mai su volumi in transizione.
#
# MODALITÀ A SECCO: CPS_DEMO_DRYRUN=1 bash scripts/demo_cleanup.sh
#   mostra gli ID che verrebbero cancellati (VM, backup, snapshot, volumi, security
#   group) e non cancella nulla; il controllo Cinder/LVM è solo diagnostico (consigliato come
#   primo passo, e prima di ogni pulizia su una macchina piccola).
#
# Uso:  bash scripts/demo_cleanup.sh

export OS_CLOUD=${CPS_CLOUD:-devstack-admin}
P=cps-demo
DRYRUN=${CPS_DEMO_DRYRUN:-0}   # 1 = elenca cosa verrebbe cancellato, senza cancellare
FAILED=0              # diventa 1 se qualcosa non si riesce a cancellare
SETTLE_TIMEOUT=90     # secondi massimi di attesa che un volume esca da in-use/detaching
DELETE_TIMEOUT=180    # secondi massimi di attesa per la cancellazione di UNA risorsa

# Senza cinder-volume attivo volumi e snapshot non si cancellano. Se non è "up" si
# richiama scripts/fix_cinder_lvm.sh (ripristino sicuro del Volume Group dopo un
# riavvio). Con Cinder "up" non si fa nulla. Se il ripristino non riesce si prosegue
# comunque: la pulizia segnalerà ciò che non è stato possibile cancellare.
# Per saltare il controllo: CPS_DEMO_SKIP_CINDER_FIX=1.
state=$(openstack volume service list --service cinder-volume -f value -c State </dev/null | head -n 1)
if [ "$state" != "up" ]; then
    echo "ATTENZIONE: cinder-volume non è 'up' (stato: ${state:-sconosciuto})."
    fix_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix_cinder_lvm.sh"
    if [ "${CPS_DEMO_SKIP_CINDER_FIX:-0}" = "1" ] || [ ! -f "$fix_script" ]; then
        echo "Volumi e snapshot potrebbero non cancellarsi. Controlla:  sudo vgs"
    else
        fix_options=()
        [ "$DRYRUN" = "1" ] && fix_options=(--check-only)
        bash "$fix_script" "${fix_options[@]}"
        case $? in
            0)  echo "Cinder/LVM ripristinato: proseguo con la pulizia." ;;
            20) echo "(a secco) servirebbe una correzione di Cinder/LVM: nessuna modifica effettuata." ;;
            10) echo "Cinder non usa il back-end LVM di DevStack: controllo non applicabile." ;;
            *)  echo "ATTENZIONE: Cinder/LVM non ripristinato (vedi sopra): volumi e snapshot potrebbero non cancellarsi." ;;
        esac
    fi
fi

# Stampa gli ID delle risorse il cui nome inizia per "cps-demo-".
# Uso: ids_of <comando di elenco...>   es. ids_of server list --all-projects
# Si lavora sugli ID (non sui nomi) e l'awk riconosce quale colonna è l'ID
# (formato UUID), così non dipende dall'ordine in cui il client stampa le colonne.
ids_of() {
    openstack "$@" -f value -c ID -c Name 2>/dev/null </dev/null | awk -v prefix="$P-" '
        NF >= 2 {
            if ($1 ~ /^[0-9a-f]{8}-/) { id = $1; name = $2 } else { id = $2; name = $1 }
            if (index(name, prefix) == 1) print id
        }'
}

# Attende (max DELETE_TIMEOUT s) che la risorsa non compaia più nell'ELENCO.
# Uso: wait_gone <id> <comando di elenco...>   es. wait_gone <id> server list --all-projects
# Si controlla l'elenco (con --all-projects dove serve) e non 'show': 'server show'
# non ha --all-projects e per una VM di un altro progetto risponderebbe "non
# trovata" anche se esiste ancora, facendo credere che la cancellazione sia finita.
wait_gone() {
    local id="$1" waited=0
    shift
    while ids_of "$@" | grep -qx "$id"; do
        sleep 3
        waited=$((waited + 3))
        [ "$waited" -ge "$DELETE_TIMEOUT" ] && return 1
    done
    return 0
}

# Attende che un volume esca dagli stati di transizione (max SETTLE_TIMEOUT s).
wait_volume_settled() {
    local waited=0 status
    while [ "$waited" -lt "$SETTLE_TIMEOUT" ]; do
        status=$(openstack volume show "$1" -f value -c status 2>/dev/null </dev/null)
        case "$status" in
            in-use|attaching|detaching|creating|deleting) sleep 3; waited=$((waited + 3)) ;;
            *) echo "$status"; return 0 ;;
        esac
    done
    echo "$status"; return 1
}

# Cancella UNA ALLA VOLTA tutte le risorse di un tipo e attende ciascuna.
# Uso: delete_all <elenco...> -- <cancella...>
#   elenco   : comando che elenca (es. volume snapshot list --all-projects); serve
#              sia a trovare gli ID sia ad attendere che spariscano
#   cancella : comando di cancellazione, a cui si aggiunge l'ID
delete_all() {
    local list_cmd=() delete_cmd=() part=0 arg id
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then part=$((part + 1)); continue; fi
        if [ "$part" = 0 ]; then list_cmd+=("$arg"); else delete_cmd+=("$arg"); fi
    done
    while read -r id; do
        [ -z "$id" ] && continue
        if [ "$DRYRUN" = "1" ]; then
            echo "   [a secco] ${delete_cmd[*]} $id"
            continue
        fi
        openstack "${delete_cmd[@]}" "$id" </dev/null || { FAILED=1; continue; }
        wait_gone "$id" "${list_cmd[@]}" \
            || { echo "ATTENZIONE: $id non ancora cancellato dopo ${DELETE_TIMEOUT}s"; FAILED=1; }
    done < <(ids_of "${list_cmd[@]}")
}

echo "== VM"
# --all-projects: senza, le VM di un altro progetto risultano "No Server found"
delete_all server list --all-projects -- server delete --all-projects --wait

echo "== Backup"
delete_all volume backup list --all-projects -- volume backup delete

echo "== Snapshot"
delete_all volume snapshot list --all-projects -- volume snapshot delete

echo "== Volumi (uno alla volta: ogni cancellazione azzera il volume)"
while read -r volume_id; do
    [ -z "$volume_id" ] && continue
    if [ "$DRYRUN" = "1" ]; then
        echo "   [a secco] volume delete $volume_id"
        continue
    fi
    status=$(wait_volume_settled "$volume_id") \
        || echo "ATTENZIONE: volume $volume_id ancora in stato '$status'"
    if [ "$status" = "error_deleting" ]; then
        openstack volume delete --force "$volume_id" </dev/null || FAILED=1
    else
        openstack volume delete "$volume_id" </dev/null || { FAILED=1; continue; }
    fi
    wait_gone "$volume_id" volume list --all-projects \
        || { echo "ATTENZIONE: volume $volume_id non ancora cancellato"; FAILED=1; }
done < <(ids_of volume list --all-projects)

echo "== Security Group"
delete_all security group list -- security group delete

if [ "$DRYRUN" = "1" ]; then
    echo
    echo "Modalità a secco: nulla è stato cancellato."
    exit 0
fi

# Verifica finale: è rimasto qualcosa?
LEFT="$(ids_of server list --all-projects) $(ids_of volume backup list --all-projects) \
$(ids_of volume snapshot list --all-projects) $(ids_of volume list --all-projects) \
$(ids_of security group list)"
# ${LEFT//[[:space:]]/} toglie spazi e a-capo: la stringa è vuota solo se non resta nulla.
if [ "$FAILED" = "1" ] || [ -n "${LEFT//[[:space:]]/}" ]; then
    echo
    echo "PULIZIA INCOMPLETA: qualcosa non è stato cancellato. Controlla l'output sopra."
    exit 1
fi
echo "Pulizia completata."
