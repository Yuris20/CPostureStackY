#!/bin/bash
# fix_cinder_lvm.sh - Ripristina il riconoscimento del Volume Group di Cinder (LVM)
# dopo un riavvio della VM DevStack, quando il loop device cambia numero.
#
# ATTENZIONE: questo script NON fa parte del plugin di analisi (che è read-only):
# è uno strumento OPERATIVO che, se serve, modifica la configurazione LVM del
# sistema. Per questo è prudente: legge, diagnostica, e interviene solo se il
# problema è dimostrato e risolvibile in modo sicuro.
#
# IL PROBLEMA
#   DevStack salva i dati di Cinder in un file (il "backing file") collegato a un
#   loop device, e scrive in /etc/lvm/lvm.conf un filtro che accetta SOLO quel loop:
#       global_filter = [ "a|loop19|", "r|.*|" ]  # from devstack
#   Dopo un riavvio il file può essere collegato a un altro loop (es. /dev/loop21):
#   il filtro continua ad accettare solo loop19, LVM ignora il disco giusto, il
#   Volume Group "sparisce" e cinder-volume resta "down".
#
# COSA FA (in ordine; ogni passo stampa cosa sta facendo)
#   1. Se il Volume Group è già visibile NON tocca la configurazione: al massimo
#      attiva volumi logici inattivi e riavvia Cinder se risulta fermo/down.
#   2. Altrimenti diagnostica la causa, distinguendo: backing file assente, loop
#      device non collegato, più loop sullo stesso file, firma LVM assente,
#      dispositivo respinto da lvm.conf (global_filter/filter), dispositivo non nel
#      devices file (use_devicesfile=1), PV senza VG, VG parziale.
#   3. Individua il loop device con 'losetup -j <backing file>' (confronta il FILE,
#      mai un numero fisso) e verifica con 'blkid -p' la firma LVM2_member.
#   4. Se la causa è il filtro: aggiunge una regola 'a|^/dev/loopN$|' PRIMA della
#      regola che respinge il dispositivo, lasciando intatte tutte le altre regole
#      (altri backend, regole di DevStack). Prima di installare: backup datato,
#      verifica che il backup sia identico e leggibile, validazione del nuovo file
#      con lvmconfig. Se dopo la modifica il VG non è visibile: ripristino
#      automatico del backup.
#   5. Se la causa è il devices file: 'lvmdevices --adddev' (con backup datato).
#   6. 'pvscan --cache', verifica del VG, attivazione dei volumi logici inattivi.
#   7. Riavvia Cinder SOLO se le verifiche precedenti sono riuscite, attende che
#      torni "up" e stampa lo stato finale con pvs, vgs, lvs.
#
# COSA NON FA MAI
#   pvcreate, vgcreate, mkfs, wipefs, vgcfgrestore o qualunque comando che
#   inizializzi/cancelli dati o metadati; non ricrea il VG se manca; non tocca file
#   fuori da /etc/lvm; non elimina volumi. Se il problema non è risolvibile in
#   sicurezza si ferma e stampa istruzioni diagnostiche.
#
# IDEMPOTENTE: rieseguirlo non duplica regole né backup; se tutto funziona non
# modifica nulla e termina con codice 0.
#
# USO
#   bash scripts/fix_cinder_lvm.sh [opzioni]
#     --check-only    solo diagnosi, non modifica nulla (codice 20 se serve una correzione)
#     --attach-loop   se il backing file non è collegato a nessun loop, lo collega
#                     ('losetup -f --show': non distruttivo). Default: non lo fa.
#     --no-restart    non riavvia Cinder (es. quando lo esegue un servizio di avvio
#                     PRIMA che Cinder parta)
#     -h, --help      questo aiuto
#
# VARIABILI (default tra parentesi)
#   CPS_CINDER_VG           (stack-volumes-lvmdriver-1)
#   CPS_CINDER_BACKING_FILE (/opt/stack/data/<VG>-backing-file)
#   CPS_CINDER_SERVICE      (devstack@c-vol)
#   CPS_LVM_CONF            (/etc/lvm/lvm.conf)
#   CPS_LVM_DEVICES_FILE    (/etc/lvm/devices/system.devices)
#   CPS_CINDER_WAIT         secondi di attesa dopo il riavvio (90)
#   CPS_CLOUD               cloud di clouds.yaml per controllare lo stato di Cinder (devstack-admin)
#
# CODICI DI USCITA
#    0  tutto a posto (o risolto)         10  backing file assente: Cinder/LVM di
#    2  uso errato                            DevStack non applicabile
#   11  backing file non collegato a un loop 12  più loop sullo stesso file
#   13  nessuna firma LVM sul dispositivo    14  PV senza VG / VG parziale / altro VG
#   15  correzione impossibile o inefficace  16  Cinder non torna "up" dopo il riavvio
#       (config ripristinata)                17  requisiti mancanti (comandi, root)
#   20  (solo --check-only) serve una correzione

set -u

VG_NAME=${CPS_CINDER_VG:-stack-volumes-lvmdriver-1}
BACKING_FILE=${CPS_CINDER_BACKING_FILE:-/opt/stack/data/${VG_NAME}-backing-file}
CINDER_SERVICE=${CPS_CINDER_SERVICE:-devstack@c-vol}
LVM_CONF=${CPS_LVM_CONF:-/etc/lvm/lvm.conf}
LVM_DEVICES_FILE=${CPS_LVM_DEVICES_FILE:-/etc/lvm/devices/system.devices}
RESTART_WAIT=${CPS_CINDER_WAIT:-90}
export OS_CLOUD=${CPS_CLOUD:-devstack-admin}

EX_USAGE=2 EX_NOT_APPLICABLE=10 EX_NO_LOOP=11 EX_MANY_LOOPS=12 EX_NO_SIGNATURE=13
EX_PV_PROBLEM=14 EX_CANNOT_FIX=15 EX_CINDER=16 EX_PREREQ=17 EX_NEEDS_FIX=20

CHECK_ONLY=0
ATTACH_LOOP=0
NO_RESTART=0

LOOP_DEV=""             # loop device individuato (es. /dev/loop21)
BACKUP_CONF=""          # backup di lvm.conf creato in QUESTA esecuzione
BACKUP_DEVICES=""       # backup del devices file creato in QUESTA esecuzione
WORKDIR=""              # cartella temporanea, rimossa all'uscita
CONFIG_TOUCHED=0        # 1 se questa esecuzione ha modificato la configurazione LVM
NEEDS_FIX=0             # in --check-only: 1 se servirebbe una correzione

# ----------------------------------------------------------------------------
# Messaggi
# ----------------------------------------------------------------------------
log()  { echo "[fix-lvm] $*"; }
step() { echo; echo "[fix-lvm] ($1) $2"; }
ok()   { echo "[fix-lvm]   OK: $*"; }
warn() { echo "[fix-lvm]   ATTENZIONE: $*" >&2; }
todo() { echo "[fix-lvm]   [solo verifica] farei: $*"; NEEDS_FIX=1; }

# Istruzioni diagnostiche manuali, stampate quando non si può proseguire in sicurezza.
diagnostic_hints() {
    cat >&2 <<EOF
[fix-lvm] Diagnosi manuale suggerita (nessuno di questi comandi modifica dati):
[fix-lvm]   sudo losetup -j $BACKING_FILE
[fix-lvm]   sudo blkid -p ${LOOP_DEV:-/dev/loopN}
[fix-lvm]   sudo pvs -a ; sudo vgs ; sudo lvs
[fix-lvm]   sudo lvmconfig devices/global_filter devices/filter devices/use_devicesfile
[fix-lvm]   sudo lvmdevices            (se usi il devices file)
[fix-lvm]   sudo pvscan --cache
[fix-lvm]   sudo journalctl -u $CINDER_SERVICE -n 50 --no-pager
[fix-lvm] Non usare pvcreate/vgcreate/mkfs/wipefs: cancellerebbero i dati dei volumi.
EOF
}

# Termina con un codice e un messaggio; ripristina la configurazione se serve.
fail() {
    local code=$1; shift
    echo "[fix-lvm] ERRORE: $*" >&2
    diagnostic_hints
    exit "$code"
}

cleanup() { [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

usage() { sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ----------------------------------------------------------------------------
# Argomenti e requisiti
# ----------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --check-only)  CHECK_ONLY=1 ;;
        --attach-loop) ATTACH_LOOP=1 ;;
        --no-restart)  NO_RESTART=1 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Opzione sconosciuta: $arg (usa --help)" >&2; exit $EX_USAGE ;;
    esac
done

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 \
        || fail $EX_PREREQ "servono i privilegi di root e 'sudo' non è disponibile"
    SUDO="sudo"
fi

# Esegue un comando con i privilegi necessari.
priv() { if [ -n "$SUDO" ]; then sudo "$@"; else "$@"; fi; }

missing=""
for cmd in losetup blkid pvs vgs lvs pvscan vgchange systemctl awk mktemp cmp diff stat install; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
[ -z "$missing" ] || fail $EX_PREREQ "comandi mancanti:$missing (installa lvm2 e util-linux)"

if [ -n "$SUDO" ] && ! sudo -n true 2>/dev/null; then
    log "Servono i privilegi di root: potrebbe essere richiesta la password di sudo."
    sudo -v || fail $EX_PREREQ "impossibile ottenere i privilegi di root"
fi

WORKDIR=$(mktemp -d) || fail $EX_PREREQ "impossibile creare una cartella temporanea"

# ----------------------------------------------------------------------------
# Funzioni di lettura (non modificano nulla)
# ----------------------------------------------------------------------------

# True se il Volume Group è visibile a LVM.
vg_visible() { priv vgs --noheadings "$VG_NAME" >/dev/null 2>&1; }

# Attributi del VG; il 4° carattere vale 'p' se il VG è PARZIALE (un PV manca).
vg_attr() { priv vgs --noheadings -o vg_attr "$VG_NAME" 2>/dev/null | tr -d ' '; }

# Elenca i volumi logici inattivi. Si ignorano quelli con il flag "activation
# skip" (10° carattere 'k', tipico degli snapshot thin): vgchange -ay non li
# attiva e non è un problema, quindi non devono causare azioni a ogni esecuzione.
inactive_lvs() {
    priv lvs --noheadings -o lv_name,lv_attr "$VG_NAME" 2>/dev/null | awk '
        NF >= 2 && substr($2, 5, 1) != "a" && substr($2, 10, 1) != "k" { print $1 }'
}

service_active() { systemctl is-active --quiet "$CINDER_SERVICE" 2>/dev/null; }

# Stato di cinder-volume secondo Cinder: up | down | unknown (CLI/credenziali assenti).
cinder_state() {
    command -v openstack >/dev/null 2>&1 || { echo unknown; return; }
    local state
    state=$(openstack volume service list --service cinder-volume -f value -c State \
            </dev/null 2>/dev/null | head -n 1)
    echo "${state:-unknown}"
}

# Individua i loop device collegati al backing file. 'losetup -j' confronta il FILE
# (dispositivo e inode), non il nome: funziona qualunque sia il numero del loop.
find_loops() { priv losetup -j "$BACKING_FILE" 2>/dev/null | cut -d: -f1 | grep '^/dev/'; }

# Firma presente sul dispositivo (sonda a basso livello, sola lettura).
device_signature() { priv blkid -p -o value -s TYPE "$1" 2>/dev/null; }

# Informazioni sul devices file di LVM (use_devicesfile, directory, system.devices).
DEVICES_FILE_IN_USE=0
report_devices_file_info() {
    local use="" dir
    dir=$(dirname "$LVM_DEVICES_FILE")
    if command -v lvmconfig >/dev/null 2>&1; then
        use=$(priv lvmconfig --type current devices/use_devicesfile 2>/dev/null | sed -n 's/.*=//p' | head -n 1)
    fi
    [ "$use" = "1" ] && DEVICES_FILE_IN_USE=1
    log "devices file: use_devicesfile=${use:-n/d (versione di LVM senza devices file)}," \
        "directory $dir $([ -d "$dir" ] && echo presente || echo assente)," \
        "$(basename "$LVM_DEVICES_FILE") $([ -e "$LVM_DEVICES_FILE" ] && echo presente || echo assente)"
}

# True se il loop device (o il backing file) è elencato nel devices file.
device_in_devices_file() {
    command -v lvmdevices >/dev/null 2>&1 || return 1
    priv lvmdevices 2>/dev/null | awk -v d="DEVNAME=$LOOP_DEV" -v f="IDNAME=$BACKING_FILE" '
        { for (i = 1; i <= NF; i++) if ($i == d || $i == f) found = 1 } END { exit !found }'
}

# ----------------------------------------------------------------------------
# Helper Python per il filtro: legge lvm.conf, valuta le regole come LVM (la prima
# che corrisponde decide) e inserisce una regola SENZA toccare le altre.
#   status <conf> <dispositivo>              -> righe "CHIAVE STATO INDICE"
#   patch  <conf> <dispositivo> <chiave> <out> -> scrive <out>; exit 3 se non serve,
#                                               4 se il filtro non è interpretabile
# ----------------------------------------------------------------------------
lvm_filter_tool() {
python3 - "$@" <<'PYEOF'
import re
import sys

QUOTED = r'"(?:[^"\\]|\\.)*"'
# Una riga NON commentata  chiave = [ "regola", "regola" ]  (anche su più righe).
ARRAY_RE = re.compile(
    r'^(?P<head>[ \t]*(?P<key>global_filter|filter)[ \t]*=[ \t]*\[)'
    r'(?P<body>(?:\s*' + QUOTED + r'\s*,?)*\s*)\]', re.M)


def parse_rule(text):
    """'a|regex|' -> (True, 'regex'); il separatore può essere qualsiasi carattere."""
    if len(text) < 3 or text[0] not in "ar":
        return None
    end = text.rfind(text[1])
    if end <= 1:
        return None
    return text[0] == "a", text[2:end]


def find_arrays(content):
    found = {}
    for match in ARRAY_RE.finditer(content):
        found[match.group("key")] = match  # se ripetuta, vale l'ultima
    return found


def rules_of(match):
    return [(q.start(), q.group(0)[1:-1])
            for q in re.finditer(QUOTED, match.group("body"))]


def evaluate(rules, device):
    """Restituisce (stato, indice): la prima regola che corrisponde decide."""
    for index, (_pos, text) in enumerate(rules):
        parsed = parse_rule(text)
        if parsed is None:
            return "unparsable", index
        accept, regex = parsed
        try:
            hit = re.search(regex, device) is not None
        except re.error:
            return "unparsable", index
        if hit:
            return ("accept" if accept else "reject"), index
    return "default-accept", -1


command, conf_path, device = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(conf_path, encoding="utf-8").read()
arrays = find_arrays(content)

if command == "status":
    for key, match in arrays.items():
        state, index = evaluate(rules_of(match), device)
        print(key, state, index)
elif command == "patch":
    key, out_path = sys.argv[4], sys.argv[5]
    match = arrays.get(key)
    if match is None:
        sys.exit(4)
    rules = rules_of(match)
    state, index = evaluate(rules, device)
    if state == "unparsable":
        sys.exit(4)
    if state != "reject":
        sys.exit(3)
    # Regola esatta e ancorata: 'loop21' senza ancore accetterebbe anche loop210.
    new_rule = "a|^" + device + "$|"
    insert_at = match.start("body") + rules[index][0]
    content = content[:insert_at] + '"' + new_rule + '", ' + content[insert_at:]
    open(out_path, "w", encoding="utf-8").write(content)
    print(new_rule)
else:
    sys.exit(2)
PYEOF
}

# ----------------------------------------------------------------------------
# Funzioni che MODIFICANO lo stato (usate solo fuori da --check-only)
# ----------------------------------------------------------------------------

# Copia datata di un file di sistema. Stampa il percorso del backup; fallisce se la
# copia non è identica all'originale e leggibile (cioè se non sarebbe ripristinabile).
backup_file() {
    local source=$1 stamp backup n=0
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="$source.cps-bak-$stamp"
    while [ -e "$backup" ]; do n=$((n + 1)); backup="$source.cps-bak-$stamp-$n"; done
    priv cp -p "$source" "$backup" || return 1
    priv test -r "$backup" || return 1
    priv cmp -s "$source" "$backup" || return 1
    echo "$backup"
}

# Sostituisce $2 con il contenuto di $1 in modo atomico, mantenendo permessi e proprietario.
install_over() {
    local source=$1 target=$2 mode owner group
    mode=$(stat -c %a "$target") && owner=$(stat -c %U "$target") \
        && group=$(stat -c %G "$target") || return 1
    priv install -m "$mode" -o "$owner" -g "$group" "$source" "$target.cps-new" \
        && priv mv -f "$target.cps-new" "$target"
}

# Valida un lvm.conf con lvmconfig, in una cartella temporanea (non tocca il sistema):
# deve essere interpretabile e, se indicato, contenere la regola attesa.
#   validate_lvm_conf <file> <chiave> [testo atteso]
validate_lvm_conf() {
    command -v lvmconfig >/dev/null 2>&1 || return 2
    local dir out
    dir=$(mktemp -d "$WORKDIR/validate.XXXXXX") || return 1
    cp "$1" "$dir/lvm.conf" || return 1
    out=$(LVM_SYSTEM_DIR="$dir" lvmconfig --type current "devices/$2" 2>/dev/null) || return 1
    [ -z "${3:-}" ] || [[ "$out" == *"$3"* ]]
}

# Ripristina i file salvati in QUESTA esecuzione (usato se la correzione non funziona).
rollback() {
    local failed=0
    if [ -n "$BACKUP_CONF" ]; then
        log "Ripristino di $LVM_CONF dal backup $BACKUP_CONF ..."
        install_over "$BACKUP_CONF" "$LVM_CONF" \
            && ok "lvm.conf ripristinato" \
            || { warn "ripristino automatico fallito: copia a mano  sudo cp -p $BACKUP_CONF $LVM_CONF"; failed=1; }
    fi
    if [ -n "$BACKUP_DEVICES" ]; then
        log "Ripristino di $LVM_DEVICES_FILE dal backup $BACKUP_DEVICES ..."
        priv cp -p "$BACKUP_DEVICES" "$LVM_DEVICES_FILE" \
            && ok "devices file ripristinato" \
            || { warn "ripristino automatico fallito: copia a mano  sudo cp -p $BACKUP_DEVICES $LVM_DEVICES_FILE"; failed=1; }
    fi
    priv pvscan --cache >/dev/null 2>&1
    return $failed
}

# Corregge il filtro di lvm.conf per le chiavi (global_filter/filter) che respingono
# il dispositivo. Ritorna 0 se ha modificato, 1 se il filtro non era la causa.
fix_filter() {
    command -v python3 >/dev/null 2>&1 \
        || fail $EX_PREREQ "serve python3 per modificare il filtro in modo sicuro"
    [ -r "$LVM_CONF" ] || fail $EX_CANNOT_FIX "$LVM_CONF non esiste o non è leggibile"

    local rejecting=() key state index
    while read -r key state index; do
        [ "$state" = "unparsable" ] \
            && fail $EX_CANNOT_FIX "$key in $LVM_CONF contiene regole che non so interpretare: correggi a mano"
        [ "$state" = "reject" ] && rejecting+=("$key")
    done < <(lvm_filter_tool status "$LVM_CONF" "$LOOP_DEV")

    if [ "${#rejecting[@]}" -eq 0 ]; then
        log "Nessuna regola di $LVM_CONF respinge $LOOP_DEV: il filtro non è la causa."
        return 1
    fi
    log "Respinto da: ${rejecting[*]} in $LVM_CONF"

    # Si prepara il nuovo file in una cartella temporanea, senza toccare il sistema.
    local current="$WORKDIR/lvm.conf.current" candidate="$WORKDIR/lvm.conf.candidate" new_rule
    cp "$LVM_CONF" "$current" || fail $EX_CANNOT_FIX "impossibile leggere $LVM_CONF"
    for key in "${rejecting[@]}"; do
        new_rule=$(lvm_filter_tool patch "$current" "$LOOP_DEV" "$key" "$candidate") \
            || fail $EX_CANNOT_FIX "impossibile inserire la regola in '$key' (filtro non interpretabile)"
        mv "$candidate" "$current"
        validate_lvm_conf "$current" "$key" "$new_rule"
        case $? in
            0) ok "nuovo '$key' validato con lvmconfig (regola aggiunta: $new_rule)" ;;
            2) fail $EX_CANNOT_FIX "lvmconfig non disponibile: non posso validare la modifica, quindi non la applico" ;;
            *) fail $EX_CANNOT_FIX "il nuovo '$key' non supera la validazione di lvmconfig: lvm.conf NON è stato modificato" ;;
        esac
    done

    log "Differenze che verrebbero applicate a $LVM_CONF:"
    diff -u "$LVM_CONF" "$current" | sed 's/^/[fix-lvm]     /'
    if [ "$CHECK_ONLY" = "1" ]; then
        todo "aggiungere la regola per $LOOP_DEV a ${rejecting[*]} (backup datato di lvm.conf incluso)"
        return 0
    fi

    BACKUP_CONF=$(backup_file "$LVM_CONF") \
        || fail $EX_CANNOT_FIX "backup di $LVM_CONF non riuscito o non verificabile: nessuna modifica effettuata"
    # Il backup deve essere davvero ripristinabile: identico e interpretabile.
    cp "$BACKUP_CONF" "$WORKDIR/backup.check" 2>/dev/null \
        && cmp -s "$WORKDIR/backup.check" "$LVM_CONF" \
        || fail $EX_CANNOT_FIX "il backup $BACKUP_CONF non è identico all'originale: nessuna modifica effettuata"
    ok "backup creato e verificato: $BACKUP_CONF"
    log "Per ripristinare a mano:  sudo cp -p $BACKUP_CONF $LVM_CONF"

    if ! install_over "$current" "$LVM_CONF"; then
        rollback
        fail $EX_CANNOT_FIX "scrittura di $LVM_CONF non riuscita (ripristinato il backup)"
    fi
    CONFIG_TOUCHED=1
    ok "$LVM_CONF aggiornato (le altre regole sono rimaste invariate)"
    return 0
}

# Aggiunge il dispositivo al devices file di LVM. Ritorna 0 se ha modificato, 1 altrimenti.
fix_devices_file() {
    command -v lvmdevices >/dev/null 2>&1 \
        || fail $EX_CANNOT_FIX "il devices file è attivo ma 'lvmdevices' non è disponibile"
    if device_in_devices_file; then
        log "$LOOP_DEV risulta già nel devices file: non è la causa."
        return 1
    fi
    if [ "$CHECK_ONLY" = "1" ]; then
        todo "lvmdevices --adddev $LOOP_DEV (backup datato di $LVM_DEVICES_FILE incluso)"
        return 0
    fi
    if [ -e "$LVM_DEVICES_FILE" ]; then
        BACKUP_DEVICES=$(backup_file "$LVM_DEVICES_FILE") \
            || fail $EX_CANNOT_FIX "backup del devices file non riuscito: nessuna modifica effettuata"
        ok "backup creato e verificato: $BACKUP_DEVICES"
    fi
    if ! priv lvmdevices --adddev "$LOOP_DEV"; then
        rollback
        fail $EX_CANNOT_FIX "'lvmdevices --adddev $LOOP_DEV' non riuscito"
    fi
    CONFIG_TOUCHED=1
    ok "$LOOP_DEV aggiunto al devices file"
    return 0
}

# Attiva i volumi logici inattivi del VG (operazione sicura e idempotente).
activate_lvs() {
    local inactive
    inactive=$(inactive_lvs)
    if [ -z "$inactive" ]; then
        ok "tutti i volumi logici sono attivi"
        return 0
    fi
    if [ "$CHECK_ONLY" = "1" ]; then
        todo "vgchange -ay $VG_NAME (volumi inattivi: $(echo "$inactive" | tr '\n' ' '))"
        return 0
    fi
    log "Volumi logici inattivi: $(echo "$inactive" | tr '\n' ' ')- eseguo vgchange -ay $VG_NAME"
    priv vgchange -ay "$VG_NAME" >/dev/null || return 1
    ok "volumi logici attivati"
}

# Riavvia Cinder e attende che torni operativo.
restart_cinder() {
    if [ "$CHECK_ONLY" = "1" ]; then
        todo "riavviare $CINDER_SERVICE"
        return 0
    fi
    if [ "$NO_RESTART" = "1" ]; then
        log "Riavvio di $CINDER_SERVICE saltato (--no-restart)."
        return 0
    fi
    log "Riavvio di $CINDER_SERVICE ..."
    priv systemctl restart "$CINDER_SERVICE" \
        || fail $EX_CINDER "systemctl restart $CINDER_SERVICE non riuscito"
    local waited=0 state
    while [ "$waited" -lt "$RESTART_WAIT" ]; do
        if service_active; then
            state=$(cinder_state)
            case "$state" in
                up) ok "cinder-volume è 'up'"; return 0 ;;
                unknown)
                    if [ "$waited" -ge 6 ]; then
                        ok "$CINDER_SERVICE attivo (stato di Cinder non verificabile: CLI openstack o credenziali assenti)"
                        return 0
                    fi ;;
            esac
        fi
        sleep 3
        waited=$((waited + 3))
    done
    fail $EX_CINDER "dopo ${RESTART_WAIT}s cinder-volume non risulta 'up' (VG visibile e volumi attivi): controlla il log con  sudo journalctl -u $CINDER_SERVICE -n 50"
}

# Stato finale con pvs, vgs, lvs e servizio.
final_report() {
    step "finale" "Stato finale"
    priv pvs 2>&1 | sed 's/^/[fix-lvm]   /'
    priv vgs "$VG_NAME" 2>&1 | sed 's/^/[fix-lvm]   /'
    priv lvs "$VG_NAME" 2>&1 | sed 's/^/[fix-lvm]   /'
    log "servizio $CINDER_SERVICE: $(systemctl is-active "$CINDER_SERVICE" 2>/dev/null) | cinder-volume: $(cinder_state)"
}

# Gestisce il caso "VG visibile": nessuna modifica alla configurazione.
handle_visible_vg() {
    local attr state
    attr=$(vg_attr)
    if [ "${attr:3:1}" = "p" ]; then
        fail $EX_PV_PROBLEM "il VG '$VG_NAME' è PARZIALE (attributi: $attr): manca un volume fisico. Non intervengo."
    fi
    activate_lvs || fail $EX_PV_PROBLEM "vgchange -ay $VG_NAME non riuscito"

    state=$(cinder_state)
    if [ "$state" = "up" ] || { [ "$state" = "unknown" ] && service_active; }; then
        ok "Cinder funziona (cinder-volume: $state, servizio $(systemctl is-active "$CINDER_SERVICE" 2>/dev/null))"
        if [ "$CHECK_ONLY" = "1" ] && [ "$NEEDS_FIX" = "1" ]; then exit $EX_NEEDS_FIX; fi
        log "Nessuna modifica necessaria."
        exit 0
    fi
    log "Il VG è a posto ma Cinder non risulta operativo (cinder-volume: $state): riavvio il servizio."
    restart_cinder
    final_report
    if [ "$CHECK_ONLY" = "1" ] && [ "$NEEDS_FIX" = "1" ]; then exit $EX_NEEDS_FIX; fi
    exit 0
}

# ============================================================================
# FLUSSO PRINCIPALE
# ============================================================================
[ "$CHECK_ONLY" = "1" ] && log "Modalità SOLO VERIFICA: non verrà modificato nulla."
log "VG: $VG_NAME | backing file: $BACKING_FILE | servizio: $CINDER_SERVICE"

step "1/7" "Stato attuale del Volume Group"
if vg_visible; then
    ok "il Volume Group '$VG_NAME' è visibile a LVM"
    handle_visible_vg
fi
warn "il Volume Group '$VG_NAME' NON è visibile: cerco la causa."

step "2/7" "Backing file di Cinder"
if [ ! -e "$BACKING_FILE" ]; then
    fail $EX_NOT_APPLICABLE "il backing file $BACKING_FILE non esiste: questo non sembra un Cinder/LVM di DevStack (o DevStack non è stato eseguito). Non creo nulla."
fi
[ -f "$BACKING_FILE" ] && [ -s "$BACKING_FILE" ] \
    || fail $EX_NOT_APPLICABLE "$BACKING_FILE non è un file regolare non vuoto"
ok "backing file presente ($(stat -c %s "$BACKING_FILE") byte)"

step "3/7" "Loop device associato al backing file"
loops=$(find_loops)
loop_count=$(echo "$loops" | grep -c '^/dev/')
if [ "$loop_count" -eq 0 ]; then
    if [ "$ATTACH_LOOP" = "1" ] && [ "$CHECK_ONLY" = "0" ]; then
        log "Nessun loop device collegato: lo collego con losetup -f --show (operazione non distruttiva)."
        LOOP_DEV=$(priv losetup -f --show "$BACKING_FILE") \
            || fail $EX_NO_LOOP "losetup -f --show non riuscito"
        ok "collegato a $LOOP_DEV"
    elif [ "$ATTACH_LOOP" = "1" ]; then
        todo "collegare il backing file a un loop device con losetup -f --show"
        exit $EX_NEEDS_FIX
    else
        fail $EX_NO_LOOP "il backing file non è collegato a nessun loop device. Ricollegalo con  sudo losetup -f --show $BACKING_FILE  oppure rilancia questo script con --attach-loop."
    fi
elif [ "$loop_count" -gt 1 ]; then
    fail $EX_MANY_LOOPS "il backing file è collegato a PIÙ loop device ($(echo $loops)): LVM vedrebbe PV duplicati. Scollega quelli non necessari (sudo losetup -d <dev>) e rilancia."
else
    LOOP_DEV=$loops
    ok "il backing file è collegato a $LOOP_DEV"
fi

step "4/7" "Firma LVM sul dispositivo"
signature=$(device_signature "$LOOP_DEV")
if [ "$signature" != "LVM2_member" ]; then
    fail $EX_NO_SIGNATURE "$LOOP_DEV non ha la firma LVM2_member (trovato: '${signature:-nessuna firma}'). Non modifico nulla e non inizializzo il disco: potrebbe contenere dati."
fi
ok "$LOOP_DEV contiene una firma LVM2_member"

step "5/7" "Perché LVM non vede il dispositivo"
report_devices_file_info
PV_OUT=$(priv pvs --noheadings -o pv_name,vg_name "$LOOP_DEV" 2>&1)
PV_RC=$?
REASON=""
if [ "$PV_RC" -eq 0 ]; then
    pv_vg=$(echo "$PV_OUT" | awk 'NR == 1 { print $2 }')
    if [ -z "$pv_vg" ]; then
        fail $EX_PV_PROBLEM "LVM vede $LOOP_DEV come PV ma senza Volume Group (metadati VG non trovati). Non ricreo nulla: si rischia la perdita dei dati."
    elif [ "$pv_vg" != "$VG_NAME" ]; then
        fail $EX_PV_PROBLEM "$LOOP_DEV appartiene al VG '$pv_vg', non a '$VG_NAME': controlla CPS_CINDER_VG."
    fi
    REASON=stale-cache
    ok "LVM vede $LOOP_DEV nel VG '$VG_NAME': probabile cache non aggiornata"
else
    log "pvs: $(echo "$PV_OUT" | head -n 1)"
    if echo "$PV_OUT" | grep -qiE 'rejected by filter|excluded by a filter|filtered'; then
        REASON=filter
    elif echo "$PV_OUT" | grep -qi 'not in devices file'; then
        REASON=devices-file
    elif [ "$DEVICES_FILE_IN_USE" = "1" ] && ! device_in_devices_file; then
        REASON=devices-file
    elif lvm_filter_tool status "$LVM_CONF" "$LOOP_DEV" 2>/dev/null | grep -q ' reject '; then
        REASON=filter     # versioni di LVM che non spiegano il rifiuto nel messaggio
    else
        fail $EX_CANNOT_FIX "causa non riconosciuta: $LOOP_DEV ha firma LVM ma LVM non lo usa e né il filtro né il devices file lo spiegano."
    fi
    ok "causa individuata: $([ "$REASON" = filter ] && echo "filtro in lvm.conf (global_filter/filter)" || echo "devices file di LVM")"
fi

step "6/7" "Correzione"
case "$REASON" in
    filter)
        fix_filter || fail $EX_CANNOT_FIX "il filtro non risulta la causa: nessuna modifica effettuata."
        ;;
    devices-file)
        fix_devices_file || fail $EX_CANNOT_FIX "il devices file non risulta la causa: nessuna modifica effettuata."
        ;;
    stale-cache)
        if [ "$CHECK_ONLY" = "1" ]; then todo "pvscan --cache"; fi
        ;;
esac

if [ "$CHECK_ONLY" = "1" ]; then
    echo
    log "Verifica terminata: serve una correzione. Esegui senza --check-only per applicarla."
    exit $EX_NEEDS_FIX
fi

step "7/7" "Verifica e riavvio di Cinder"
log "Aggiorno la cache di LVM: pvscan --cache"
priv pvscan --cache >/dev/null 2>&1
if ! vg_visible; then
    [ "$CONFIG_TOUCHED" = "1" ] && rollback
    fail $EX_CANNOT_FIX "dopo la correzione il VG '$VG_NAME' è ancora invisibile: $([ "$CONFIG_TOUCHED" = "1" ] && echo "configurazione ripristinata dal backup" || echo "nessuna modifica era stata fatta")."
fi
ok "il Volume Group '$VG_NAME' è tornato visibile"

attr=$(vg_attr)
if [ "${attr:3:1}" = "p" ]; then
    fail $EX_PV_PROBLEM "il VG '$VG_NAME' è visibile ma PARZIALE (attributi: $attr): non riavvio Cinder."
fi
activate_lvs || fail $EX_PV_PROBLEM "vgchange -ay $VG_NAME non riuscito: non riavvio Cinder."

restart_cinder
final_report

if [ "$CONFIG_TOUCHED" = "1" ]; then
    echo
    log "Fatto. Backup della configurazione precedente: ${BACKUP_CONF:-$BACKUP_DEVICES}"
    log "Nota: le regole preesistenti di lvm.conf (anche riferite a vecchi loop) sono state lasciate invariate."
fi
exit 0
