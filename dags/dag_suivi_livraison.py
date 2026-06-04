"""
DAG : Suivi en temps réel des livraisons
Déclencheur : Schedule toutes les 15 minutes

Logique :
  1. Récupère tous les colis avec statut actif (En transit / Expédié / En préparation)
  2. Met à jour les statuts dans statut_livraison (OLTP)
  3. Vérifie les retards (date_livraison_prevue dépassée)
  4. Branch selon le statut détecté :
       - Livré             → marquer_livre (met à jour warehouse.fait_livraison)
       - Retard / Incident → declencher_alerte (crée un incident)
       - Non livré         → creer_retour (insère dans retour + warehouse.fait_retour)
"""

from airflow import DAG
from airflow.operators.python import PythonOperator, BranchPythonOperator
from airflow.operators.empty import EmptyOperator
from datetime import datetime, timedelta
from sqlalchemy import create_engine, text
import logging

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────
DB_URL = "postgresql+psycopg2://livraison:livraison_pass@postgres-livraison:5432/livraison_db"


def get_engine():
    return create_engine(DB_URL)


# ──────────────────────────────────────────────────────────────
# Tâches
# ──────────────────────────────────────────────────────────────

def recuperer_statuts(**context):
    """
    Lit tous les colis dont le statut est encore actif dans dim_colis
    et récupère leur dernière entrée dans statut_livraison.
    Pousse la liste dans XCom pour les tâches suivantes.
    """
    engine = get_engine()
    with engine.connect() as conn:
        rows = conn.execute(text("""
            SELECT
                dc.id_source        AS colis_id,
                dc.code_suivi,
                sl.statut           AS dernier_statut,
                sl.horodatage       AS derniere_maj,
                sl.localisation,
                fl.id_fait_livraison,
                fl.id_dim_temps_livraison
            FROM warehouse.dim_colis dc
            LEFT JOIN LATERAL (
                SELECT statut, horodatage, localisation
                FROM statut_livraison
                WHERE colis_id = dc.id_source
                ORDER BY horodatage DESC
                LIMIT 1
            ) sl ON TRUE
            LEFT JOIN warehouse.fait_livraison fl
                ON fl.id_dim_colis = dc.id_dim_colis
            WHERE sl.statut IS NULL
               OR sl.statut NOT IN ('Livré', 'Retourné')
        """)).fetchall()

    statuts = [
        {
            "colis_id":           r.colis_id,
            "code_suivi":         r.code_suivi,
            "dernier_statut":     r.dernier_statut,
            "derniere_maj":       str(r.derniere_maj) if r.derniere_maj else None,
            "localisation":       r.localisation,
            "id_fait_livraison":  r.id_fait_livraison,
        }
        for r in rows
    ]

    logging.info(f"{len(statuts)} colis actifs récupérés")
    context["ti"].xcom_push(key="statuts", value=statuts)


def mettre_a_jour_statuts(**context):
    """
    Insère une nouvelle ligne dans statut_livraison pour chaque colis
    actif afin d'horodater la vérification périodique.
    """
    statuts = context["ti"].xcom_pull(key="statuts", task_ids="recuperer_statuts")
    if not statuts:
        logging.info("Aucun colis actif — rien à mettre à jour")
        return

    engine = get_engine()
    with engine.begin() as conn:
        for s in statuts:
            conn.execute(text("""
                INSERT INTO statut_livraison (colis_id, statut, localisation)
                VALUES (:colis_id, :statut, :localisation)
            """), {
                "colis_id":    s["colis_id"],
                "statut":      s["dernier_statut"] or "En transit",
                "localisation": s["localisation"] or "Inconnu",
            })

    logging.info(f"{len(statuts)} lignes insérées dans statut_livraison")


def verifier_retards(**context):
    """
    Compare date_livraison_prevue (dim_colis enrichi via fait_livraison)
    avec la date du jour.  Pousse dans XCom :
      - colis_livres     : colis dont le statut OLTP = 'Livré'
      - colis_en_retard  : date_livraison_prevue < TODAY et statut ≠ 'Livré'
      - colis_normaux    : tout le reste
    """
    engine = get_engine()
    today = datetime.now().date()

    with engine.connect() as conn:
        rows = conn.execute(text("""
            SELECT
                dc.id_source        AS colis_id,
                dc.code_suivi,
                sl.statut,
                dt_prev.date_complete AS date_livraison_prevue,
                fl.id_fait_livraison
            FROM warehouse.dim_colis dc
            JOIN warehouse.fait_livraison fl ON fl.id_dim_colis = dc.id_dim_colis
            LEFT JOIN warehouse.dim_temps dt_prev
                ON dt_prev.id_dim_temps = fl.id_dim_temps_livraison
            LEFT JOIN LATERAL (
                SELECT statut
                FROM statut_livraison
                WHERE colis_id = dc.id_source
                ORDER BY horodatage DESC
                LIMIT 1
            ) sl ON TRUE
            WHERE (sl.statut IS NULL OR sl.statut NOT IN ('Livré', 'Retourné'))
        """)).fetchall()

    livres, retards, normaux = [], [], []
    for r in rows:
        entry = {
            "colis_id":          r.colis_id,
            "code_suivi":        r.code_suivi,
            "statut":            r.statut,
            "id_fait_livraison": r.id_fait_livraison,
            "date_prevue":       str(r.date_livraison_prevue) if r.date_livraison_prevue else None,
        }
        if r.statut == "Livré":
            livres.append(entry)
        elif r.date_livraison_prevue and r.date_livraison_prevue < today:
            retards.append(entry)
        else:
            normaux.append(entry)

    logging.info(f"Livrés={len(livres)} | En retard={len(retards)} | Normaux={len(normaux)}")
    ti = context["ti"]
    ti.xcom_push(key="colis_livres",    value=livres)
    ti.xcom_push(key="colis_en_retard", value=retards)
    ti.xcom_push(key="colis_normaux",   value=normaux)


def brancher_selon_statut(**context):
    """
    Décide quelle(s) branche(s) exécuter selon les listes XCom.
    """
    ti = context["ti"]
    livres  = ti.xcom_pull(key="colis_livres",    task_ids="verifier_retards") or []
    retards = ti.xcom_pull(key="colis_en_retard", task_ids="verifier_retards") or []

    branches = []
    if livres:
        branches.append("marquer_livre")
    if retards:
        branches.append("declencher_alerte")
    if not livres and not retards:
        branches.append("fin_sans_action")

    logging.info(f"Branches sélectionnées : {branches}")
    return branches


def marquer_livre(**context):
    """
    Pour chaque colis livré :
      - Met à jour warehouse.fait_livraison (date de livraison réelle + délai)
      - Insère un statut final dans statut_livraison
    """
    livres = context["ti"].xcom_pull(key="colis_livres", task_ids="verifier_retards") or []
    if not livres:
        return

    engine = get_engine()
    today  = datetime.now().date()

    with engine.begin() as conn:
        # Récupère l'id_dim_temps pour aujourd'hui
        result = conn.execute(text("""
            SELECT id_dim_temps FROM warehouse.dim_temps
            WHERE date_complete = :today
        """), {"today": today}).fetchone()

        id_temps_aujourd_hui = result[0] if result else None

        for c in livres:
            if c["id_fait_livraison"] and id_temps_aujourd_hui:
                conn.execute(text("""
                    UPDATE warehouse.fait_livraison
                    SET
                        id_dim_temps_livraison = :id_temps,
                        statut_livraison       = 'Livré',
                        livraison_dans_delai   = (
                            :today <= (
                                SELECT date_complete
                                FROM warehouse.dim_temps
                                WHERE id_dim_temps = id_dim_temps_livraison
                            )
                        )
                    WHERE id_fait_livraison = :id_fait
                """), {
                    "id_temps": id_temps_aujourd_hui,
                    "today":    today,
                    "id_fait":  c["id_fait_livraison"],
                })

            # Statut OLTP final
            conn.execute(text("""
                INSERT INTO statut_livraison (colis_id, statut, localisation)
                VALUES (:colis_id, 'Livré', 'Destination finale')
            """), {"colis_id": c["colis_id"]})

    logging.info(f"{len(livres)} colis marqués comme livrés")


def declencher_alerte(**context):
    """
    Pour chaque colis en retard, crée un incident dans la table incident.
    """
    retards = context["ti"].xcom_pull(key="colis_en_retard", task_ids="verifier_retards") or []
    if not retards:
        return

    engine = get_engine()
    with engine.begin() as conn:
        for c in retards:
            # Vérifie qu'un incident ouvert n'existe pas déjà
            existing = conn.execute(text("""
                SELECT id FROM incident
                WHERE colis_id = :colis_id
                  AND type_incident = 'RETARD'
                  AND statut = 'ouvert'
            """), {"colis_id": c["colis_id"]}).fetchone()

            if not existing:
                conn.execute(text("""
                    INSERT INTO incident
                        (colis_id, type_incident, priorite, description, statut)
                    VALUES
                        (:colis_id, 'RETARD', 'HAUTE',
                         :description, 'ouvert')
                """), {
                    "colis_id":    c["colis_id"],
                    "description": (
                        f"Colis {c['code_suivi']} en retard. "
                        f"Date prévue : {c.get('date_prevue', 'inconnue')}. "
                        f"Statut actuel : {c.get('statut', 'inconnu')}."
                    ),
                })

    logging.info(f"{len(retards)} alertes retard créées")


def fin_sans_action(**context):
    """Tâche de terminaison quand il n'y a rien à faire."""
    logging.info("Aucune action requise pour ce cycle.")


# ──────────────────────────────────────────────────────────────
# Définition du DAG
# ──────────────────────────────────────────────────────────────
default_args = {
    "owner":       "livraison",
    "retries":     1,
    "retry_delay": timedelta(minutes=2),
}

with DAG(
    dag_id="dag_suivi_livraison",
    default_args=default_args,
    start_date=datetime(2024, 1, 1),
    schedule_interval="*/15 * * * *",
    catchup=False,
    tags=["livraison", "suivi", "warehouse"],
) as dag:

    t1 = PythonOperator(
        task_id="recuperer_statuts",
        python_callable=recuperer_statuts,
    )
    t2 = PythonOperator(
        task_id="mettre_a_jour_statuts",
        python_callable=mettre_a_jour_statuts,
    )
    t3 = PythonOperator(
        task_id="verifier_retards",
        python_callable=verifier_retards,
    )
    t4 = BranchPythonOperator(
        task_id="brancher_selon_statut",
        python_callable=brancher_selon_statut,
    )
    t5a = PythonOperator(
        task_id="marquer_livre",
        python_callable=marquer_livre,
    )
    t5b = PythonOperator(
        task_id="declencher_alerte",
        python_callable=declencher_alerte,
    )
    t5c = PythonOperator(
        task_id="fin_sans_action",
        python_callable=fin_sans_action,
    )

    t1 >> t2 >> t3 >> t4 >> [t5a, t5b, t5c]