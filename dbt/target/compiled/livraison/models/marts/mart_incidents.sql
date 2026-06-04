-- Mart : synthese des incidents et alertes
with incidents as (
    select * from "livraison_db"."public"."incident"
),
colis as (
    select * from "livraison_db"."staging"."stg_colis"
)
select
    i.id            as incident_id,
    i.colis_id,
    c.reference_tracking,
    i.type_incident,
    i.priorite,
    i.description,
    i.signale_le::date as date_incident,
    i.statut
from incidents i
left join colis c using (colis_id)
order by i.signale_le desc