"""
DAG : Gestion des retours
Déclencheur : SqlSensor sur la table `retour` (statut = 'INITIE')

Pipeline :
  1. detecter_retour    — SqlSensor : attend un retour avec statut INITIE
  2. inspecter_colis    — Lit le retour + le colis associé, pousse les infos en XCom
  3. calculer_remboursement — Calcule le montant TTC à rembourser via warehouse.fait_livraison
  4. creer_avoir        — Insère dans warehouse.fait_retour + met à jour dim_colis
  5. cloturer_retour    — Passe le statut de la table `retour` à 'CLOTURE'
"""

from airflow import DAG
from airflow.providers.postgres.sensors.sql import SqlSensor
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
from sqlalchemy import create_engine, text
import logging

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────
DB_URL = "postgresql+psycopg2://livraison:livraison_pass@postgres-livraison:5432/livraison_db"

# Frais forfaitaires de retour (Ariary)
FRAIS_RETOUR_FORFAIT = 5000


def get_engine():
    return create_engine(DB_URL)


# ──────────────────────────────────────────────────────────────
# Tâches
# ──────────────────────────────────────────────────────────────

def inspecter_colis(**context):
    """
    Récupère le premier retour en statut INITIE et le colis associé.
    Pousse toutes les infos nécessaires dans XCom.
    """
    engine = get_engine()
    with engine.connect() as conn:
        # Retour OLTP
        retour = conn.execute(text("""
            SELECT id_retour, id_colis, id_client, date_retour, motif, commentaire
            FROM retour
            WHERE statut = 'INITIE'
            ORDER BY date_retour ASC
            LIMIT 1
        """)).fetchone()

        if not retour:
            logging.warning("Aucun retour INITIE trouvé — tâche ignorée")
            return

        id_retour, id_colis, id_client, date_retour, motif, commentaire = retour

        # Infos du colis dans le warehouse
        colis = conn.execute(text("""
            SELECT id_dim_colis, code_suivi, type_colis, poids_kg, fragile, expediteur, destinataire
            FROM warehouse.dim_colis
            WHERE id_source = :id_colis
            LIMIT 1
        """), {"id_colis": id_colis}).fetchone()

        # Fait livraison associé (pour récupérer montant_ttc)
        fait_liv = conn.execute(text("""
            SELECT fl.id_fait_livraison, fl.montant_ttc, fl.frais_livraison,
                   dg.ville AS ville_arrivee
            FROM warehouse.fait_livraison fl
            LEFT JOIN warehouse.dim_geo dg ON dg.id_dim_geo = fl.id_dim_geo_arrivee
            WHERE fl.id_dim_colis = :id_dim_colis
            LIMIT 1
        """), {"id_dim_colis": colis.id_dim_colis if colis else None}).fetchone()

    info = {
        "id_retour":         id_retour,
        "id_colis":          id_colis,
        "id_client":         id_client,
        "date_retour":       str(date_retour),
        "motif":             motif,
        "commentaire":       commentaire,
        "id_dim_colis":      colis.id_dim_colis       if colis   else None,
        "code_suivi":        colis.code_suivi          if colis   else None,
        "fragile":           colis.fragile             if colis   else False,
        "id_fait_livraison": fait_liv.id_fait_livraison if fait_liv else None,
        "montant_ttc":       float(fait_liv.montant_ttc) if fait_liv and fait_liv.montant_ttc else None,
        "ville_retour":      fait_liv.ville_arrivee    if fait_liv else "Antananarivo",
    }

    logging.info(f"Retour {id_retour} inspecté — colis {info['code_suivi']}, motif : {motif}")
    context["ti"].xcom_push(key="retour_info", value=info)


def calculer_remboursement(**context):
    """
    Calcule le montant à rembourser selon le motif :
      - Colis endommagé / Produit défectueux / Erreur de produit → remboursement TTC complet
      - Refus du client                                           → remboursement TTC - frais retour
      - Adresse incorrecte                                        → remboursement TTC - frais retour
      - Autre                                                     → remboursement TTC - frais retour
    Pousse le montant calculé en XCom.
    """
    info = context["ti"].xcom_pull(key="retour_info", task_ids="inspecter_colis")
    if not info:
        logging.warning("Pas d'info retour disponible")
        return

    motif = (info.get("motif") or "").lower()
    montant_ttc = info.get("montant_ttc") or 0.0

    motifs_remboursement_total = [
        "colis endommagé",
        "produit défectueux",
        "erreur de produit",
    ]

    if any(m in motif for m in motifs_remboursement_total):
        montant_rembourse = montant_ttc
        logging.info(f"Remboursement total : {montant_rembourse} Ar (motif: {motif})")
    else:
        montant_rembourse = max(0.0, montant_ttc - FRAIS_RETOUR_FORFAIT)
        logging.info(
            f"Remboursement partiel : {montant_rembourse} Ar "
            f"(TTC {montant_ttc} - frais {FRAIS_RETOUR_FORFAIT} | motif: {motif})"
        )

    context["ti"].xcom_push(key="montant_rembourse", value=montant_rembourse)


def creer_avoir(**context):
    """
    - Insère une ligne dans warehouse.fait_retour
    - Met à jour warehouse.fait_livraison (statut_livraison → 'Retourné')
    """
    ti   = context["ti"]
    info = ti.xcom_pull(key="retour_info",      task_ids="inspecter_colis")
    montant_rembourse = ti.xcom_pull(key="montant_rembourse", task_ids="calculer_remboursement")

    if not info:
        logging.warning("Pas d'info retour — avoir non créé")
        return

    engine     = get_engine()
    date_retour = datetime.strptime(info["date_retour"][:10], "%Y-%m-%d").date()

    with engine.begin() as conn:
        # Récupère id_dim_temps pour la date du retour
        temps = conn.execute(text("""
            SELECT id_dim_temps FROM warehouse.dim_temps
            WHERE date_complete = :d LIMIT 1
        """), {"d": date_retour}).fetchone()

        id_dim_temps = temps[0] if temps else None

        # Récupère id_dim_client
        client = conn.execute(text("""
            SELECT id_dim_client FROM warehouse.dim_client
            WHERE id_source = :id_client LIMIT 1
        """), {"id_client": info["id_client"]}).fetchone()

        id_dim_client = client[0] if client else None

        # Récupère id_dim_geo pour la ville de retour
        geo = conn.execute(text("""
            SELECT id_dim_geo FROM warehouse.dim_geo
            WHERE ville = :ville LIMIT 1
        """), {"ville": info.get("ville_retour", "Antananarivo")}).fetchone()

        id_dim_geo = geo[0] if geo else None

        # Calcul délai retour (jours depuis livraison)
        delai_retour = None
        if info.get("id_fait_livraison"):
            row = conn.execute(text("""
                SELECT dt.date_complete
                FROM warehouse.fait_livraison fl
                JOIN warehouse.dim_temps dt ON dt.id_dim_temps = fl.id_dim_temps_livraison
                WHERE fl.id_fait_livraison = :id_fait
            """), {"id_fait": info["id_fait_livraison"]}).fetchone()
            if row and row[0]:
                delai_retour = (date_retour - row[0]).days

        # Insertion warehouse.fait_retour
        conn.execute(text("""
            INSERT INTO warehouse.fait_retour (
                id_dim_temps_retour,
                id_dim_client,
                id_dim_colis,
                id_dim_geo_retour,
                id_fait_livraison,
                id_retour,
                motif_retour,
                commentaire,
                montant_ttc_retourne,
                frais_retour,
                delai_retour_jours
            ) VALUES (
                :id_dim_temps, :id_dim_client, :id_dim_colis,
                :id_dim_geo, :id_fait_livraison,
                :id_retour, :motif, :commentaire,
                :montant_ttc_retourne, :frais_retour, :delai_retour
            )
        """), {
            "id_dim_temps":        id_dim_temps,
            "id_dim_client":       id_dim_client,
            "id_dim_colis":        info.get("id_dim_colis"),
            "id_dim_geo":          id_dim_geo,
            "id_fait_livraison":   info.get("id_fait_livraison"),
            "id_retour":           info["id_retour"],
            "motif":               info.get("motif"),
            "commentaire":         info.get("commentaire"),
            "montant_ttc_retourne": montant_rembourse,
            "frais_retour":        FRAIS_RETOUR_FORFAIT,
            "delai_retour":        delai_retour,
        })

        # Mise à jour du statut de livraison dans warehouse
        if info.get("id_fait_livraison"):
            conn.execute(text("""
                UPDATE warehouse.fait_livraison
                SET statut_livraison = 'Retourné'
                WHERE id_fait_livraison = :id_fait
            """), {"id_fait": info["id_fait_livraison"]})

    logging.info(
        f"Avoir créé pour retour {info['id_retour']} — "
        f"remboursement : {montant_rembourse} Ar"
    )


def cloturer_retour(**context):
    """
    Passe le statut du retour OLTP de 'INITIE' à 'CLOTURE'.
    """
    info = context["ti"].xcom_pull(key="retour_info", task_ids="inspecter_colis")
    if not info:
        logging.warning("Pas d'info retour — clôture ignorée")
        return

    engine = get_engine()
    with engine.begin() as conn:
        conn.execute(text("""
            UPDATE retour
            SET statut = 'CLOTURE'
            WHERE id_retour = :id_retour
        """), {"id_retour": info["id_retour"]})

    logging.info(f"Retour {info['id_retour']} clôturé avec succès")


# ──────────────────────────────────────────────────────────────
# Définition du DAG
# ──────────────────────────────────────────────────────────────
default_args = {
    "owner":   "livraison",
    "retries": 2,
    "retry_delay": timedelta(minutes=3),
}

with DAG(
    dag_id="dag_gestion_retour",
    default_args=default_args,
    start_date=datetime(2024, 1, 1),
    schedule_interval="*/10 * * * *",
    catchup=False,
    tags=["retour", "warehouse"],
) as dag:

    detecter_retour = SqlSensor(
        task_id="detecter_retour",
        conn_id="postgres_livraison",
        sql="SELECT COUNT(*) FROM retour WHERE statut = 'INITIE'",
        poke_interval=60,
        timeout=600,
        mode="reschedule",
    )

    t1 = PythonOperator(
        task_id="inspecter_colis",
        python_callable=inspecter_colis,
    )
    t2 = PythonOperator(
        task_id="calculer_remboursement",
        python_callable=calculer_remboursement,
    )
    t3 = PythonOperator(
        task_id="creer_avoir",
        python_callable=creer_avoir,
    )
    t4 = PythonOperator(
        task_id="cloturer_retour",
        python_callable=cloturer_retour,
    )

    detecter_retour >> t1 >> t2 >> t3 >> t4