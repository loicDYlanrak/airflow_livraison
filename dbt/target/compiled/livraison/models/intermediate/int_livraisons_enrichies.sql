-- Intermediaire : joint colis + statuts + commande
with colis as (
    select * from "livraison_db"."staging"."stg_colis"
),
commandes as (
    select * from "livraison_db"."staging"."stg_commandes"
),
derniers_statuts as (
    select distinct on (colis_id)
        colis_id,
        statut        as dernier_statut,
        statut_ts     as derniere_maj,
        localisation
    from "livraison_db"."staging"."stg_statuts_livraison"
    order by colis_id, statut_ts desc
)
select
    c.colis_id,
    c.reference_tracking,
    c.poids_kg,
    c.statut_actuel,
    com.commande_id,
    com.commande_ts,
    com.montant_total,
    ds.dernier_statut,
    ds.derniere_maj,
    ds.localisation
from colis c
left join commandes com using (commande_id)
left join derniers_statuts ds using (colis_id)