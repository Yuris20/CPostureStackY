#!/bin/bash
# plugin.sh - Integrazione di CPostureStackY in DevStack.
#
# DevStack chiama questo file più volte durante stack.sh, passando due
# parametri: $1 (fase generale, es. "stack") e $2 (sotto-fase, es. "install"
# o "extra"). Noi reagiamo solo alle due fasi che ci servono.
#
# Attivazione (nel file local.conf):
#   enable_plugin cpostureStacky https://github.com/Yuris20/CPostureStackY
#   enable_service cpostureStacky
#
# Variabili opzionali (tutte lette da cpostureStacky/config.py, che contiene i
# valori di default): CPS_CLOUD, CPS_REPORTS_DIR, CPS_BACKUP_MAX_AGE_DAYS,
# CPS_RAM_WARN, CPS_VCPU_WARN, CPS_USAGE_CRIT, CPS_REPORT_UNUSED_SG, CPS_LOG_LEVEL.

# Variabili CPS_* che, se definite nel local.conf, vanno passate al programma Python.
CPS_FORWARDED_VARS="CPS_CLOUD CPS_REPORTS_DIR CPS_BACKUP_MAX_AGE_DAYS \
CPS_SNAPSHOT_MAX_AGE_DAYS CPS_RAM_WARN CPS_VCPU_WARN CPS_USAGE_CRIT \
CPS_REPORT_UNUSED_SG CPS_LOG_LEVEL"

# Fase "install": prepara le dipendenze
function install_cpostureStacky {
    # openstacksdk è già installato da DevStack; lo garantiamo comunque.
    # pip_install è una funzione fornita da DevStack (rispetta i suoi vincoli
    # di versione, per questo requirements.txt non viene usato qui).
    pip_install openstacksdk
}

# Fase "extra": lancia l'analisi
function run_cpostureStacky {
    echo_summary "CPostureStackY: analisi della postura del cloud (read-only)"
    [ -x "$CPS_PYTHON" ] || CPS_PYTHON=python3

    # Le parentesi ( ... ) eseguono i comandi in una sub-shell, così il
    # 'cd' e gli 'export' non cambiano l'ambiente di DevStack.
    # Si esportano SOLO le variabili definite: quelle assenti lasciano ai
    # default di config.py (un'unica fonte dei valori predefiniti).
    # Dopo la parentesi, "|| echo ..." fa sì che un eventuale errore (codice 1:
    # connessione non riuscita; codice 2: almeno un controllo non completato)
    # stampi solo un avviso e NON faccia fallire il deployment.
    ( cd "$CPS_DIR" || exit 1
      for cps_var in $CPS_FORWARDED_VARS; do
          if [ -n "${!cps_var}" ]; then
              export "$cps_var"
          fi
      done
      "$CPS_PYTHON" -m cpostureStacky.main ) \
      || echo "CPostureStackY: analisi non completata o parziale (deployment non influenzato)"
}

# Il codice sotto viene eseguito solo se il servizio è abilitato nel local.conf
if is_service_enabled cpostureStacky; then
    if [[ "$1" == "stack" && "$2" == "install" ]]; then
        install_cpostureStacky
    elif [[ "$1" == "stack" && "$2" == "extra" ]]; then
        # "extra" è l'ultima fase: tutti i servizi OpenStack sono già attivi,
        # quindi possiamo interrogarli.
        run_cpostureStacky
    fi
    # Fasi "unstack" e "clean": non facciamo nulla, il plugin non crea risorse.
fi
