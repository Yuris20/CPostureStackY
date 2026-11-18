#!/bin/bash
# demo_cleanup.sh - Rimuove le risorse create da demo_setup.sh con gestione robusta degli errori.

export OS_CLOUD=${CPS_CLOUD:-devstack-admin}
P="cps-demo"

# CONTROLLO CINDER/LVM
state=$(openstack volume service list --service cinder-volume -f value -c State </dev/null 2>/dev/null | head -n 1)
if [ "$state" != "up" ]; then
    fix_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix_cinder_lvm.sh"
    [ -f "$fix_script" ] && [ "${CPS_DEMO_SKIP_CINDER_FIX:-0}" != "1" ] && bash "$fix_script" >/dev/null 2>&1
fi

get_ids() {
    openstack "$@" -f value -c ID -c Name 2>/dev/null | grep "$P-" | awk '{print $1}'
}

echo "== 1. Eliminazione VM =="
for id in $(get_ids server list --all-projects); do
    openstack server delete --all-projects --wait "$id" >/dev/null 2>&1 \
        && echo "   [OK] VM $id eliminata" \
        || echo "   [AVVISO] Impossibile eliminare la VM $id"
done

echo "== 2. Eliminazione Backup =="
for id in $(get_ids volume backup list --all-projects); do
    # Tenta il reset e la cancellazione via API
    openstack volume backup set --state available "$id" >/dev/null 2>&1
    openstack volume backup delete --force "$id" >/dev/null 2>&1
    
    # Se esiste ancora, prova il fallback diretto su MySQL
    if openstack volume backup show "$id" >/dev/null 2>&1; then
        sudo mysql -u root -pOpenStack123 cinder -e "DELETE FROM backups WHERE id = '$id';" >/dev/null 2>&1
    fi

    # Controllo finale
    if openstack volume backup show "$id" >/dev/null 2>&1; then
        echo "   [AVVISO] Backup $id non rimovibile via API/DB, richiede attenzione."
    else
        echo "   [OK] Backup $id eliminato"
    fi
done

echo "== 3. Eliminazione Snapshot =="
for id in $(get_ids volume snapshot list --all-projects); do
    openstack volume snapshot delete "$id" >/dev/null 2>&1 \
        && echo "   [OK] Snapshot $id eliminata" \
        || echo "   [AVVISO] Impossibile eliminare la snapshot $id"
done

echo "== 4. Eliminazione Volumi =="
for id in $(get_ids volume list --all-projects); do
    openstack volume delete "$id" >/dev/null 2>&1 || openstack volume delete --force "$id" >/dev/null 2>&1
    if openstack volume show "$id" >/dev/null 2>&1; then
        echo "   [AVVISO] Volume $id non eliminato correttamente"
    else
        echo "   [OK] Volume $id eliminato"
    fi
done

echo "== 5. Eliminazione Security Group =="
for id in $(get_ids security group list); do
    openstack security group delete "$id" >/dev/null 2>&1 \
        && echo "   [OK] Security Group $id eliminato" \
        || echo "   [AVVISO] Impossibile eliminare il Security Group $id (potrebbe essere ancora in uso da qualche porta)"
done

echo "Pulizia completata."
