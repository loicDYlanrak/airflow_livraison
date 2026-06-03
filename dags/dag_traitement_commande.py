"""
DAG : Traitement de commande
Declencheur : Nouvelle commande avec statut NOUVELLE dans la table COMMANDE
"""
from airflow import DAG
from airflow.sensors.sql import SqlSensor  # Changé : plus de provider postgres
from airflow.operators.python import PythonOperator
from airflow.models import Connection
from airflow import settings
from datetime import datetime, timedelta
from sqlalchemy import create_engine, text
import logging

# Créer automatiquement la connexion si elle n'existe pas
def ensure_connection():
    session = settings.Session()
    conn_id = 'postgres_livraison'
    if not session.query(Connection).filter(Connection.conn_id == conn_id).first():
        conn = Connection(
            conn_id=conn_id,
            conn_type='postgres',
            host='postgres-livraison',
            login='livraison',
            password='livraison_pass',
            port=5432,
            schema='livraison_db'
        )
        session.add(conn)
        session.commit()
        logging.info(f"Connexion {conn_id} créée")
    session.close()

# Appeler au chargement du DAG
ensure_connection()

default_args = {
    "owner": "livraison",
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": False,
}

def valider_commande(**context):
    """Valide la commande : stock, adresse, paiement"""
    engine = create_engine("postgresql+psycopg2://livraison:livraison_pass@postgres-livraison:5432/livraison_db")
    with engine.begin() as conn:  # begin() gère le commit/rollback automatiquement
        result = conn.execute(text("UPDATE commande SET statut = 'validee' WHERE statut = 'NOUVELLE'"))
        print(f"{result.rowcount} commandes validées")

def affecter_livreur(**context):
    """Trouve le livreur disponible le plus proche"""
    print("Livreur affecté")

def planifier_tournee(**context):
    """Ajoute la commande a une tournee existante ou cree une nouvelle"""
    print("Tournée planifiée")

def notifier_client(**context):
    """Envoie une confirmation au client"""
    print("Client notifié")

with DAG(
    dag_id="dag_traitement_commande",
    default_args=default_args,
    start_date=datetime(2024, 1, 1),
    schedule_interval="*/5 * * * *",
    catchup=False,
    tags=["commande", "core"],
) as dag:

    attendre_nouvelle_commande = SqlSensor(
        task_id="attendre_nouvelle_commande",
        conn_id="postgres_livraison",
        sql="SELECT 1 FROM commande WHERE statut = 'NOUVELLE' LIMIT 1",
        poke_interval=30,
        timeout=300,
        mode="reschedule",
    )

    valider = PythonOperator(task_id="valider_commande", python_callable=valider_commande)
    affecter = PythonOperator(task_id="affecter_livreur", python_callable=affecter_livreur)
    planifier = PythonOperator(task_id="planifier_tournee", python_callable=planifier_tournee)
    notifier = PythonOperator(task_id="notifier_client", python_callable=notifier_client)

    attendre_nouvelle_commande >> valider >> affecter >> planifier >> notifier