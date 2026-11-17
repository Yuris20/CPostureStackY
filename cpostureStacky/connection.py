"""connection.py - Connessione a OpenStack.

Questo modulo ha UN solo compito: creare l'oggetto di connessione.
Tutti i check ricevono questo oggetto (di solito chiamato 'conn') e lo usano
per interrogare Neutron, Nova e Cinder.
"""
import openstack


def get_connection(cloud_name):
    """Restituisce una connessione openstacksdk al cloud indicato.

    Come funziona l'autenticazione:
      openstack.connect(cloud="devstack-admin") cerca il file clouds.yaml
      (in /etc/openstack/ oppure ~/.config/openstack/) e legge da lì URL di
      Keystone, utente, password e progetto. Quindi NESSUNA password è
      scritta nel nostro codice, nei log o nel report.

    Nota: la connessione è "pigra": l'autenticazione vera avviene alla prima
    richiesta (es. conn.compute.servers()), non qui. Un errore di credenziali
    emerge quindi nei check, che lo segnalano come "controllo non completato".

    READ-ONLY: la connessione di per sé non modifica nulla; sono i check a
    garantire di usare solo chiamate di lettura (list/get).
    """
    return openstack.connect(cloud=cloud_name)
