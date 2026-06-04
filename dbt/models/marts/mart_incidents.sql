-- Mart : synthèse des incidents (sans jointure colis — non dispo en PG)
with incidents as (
    select * from {{ source('livraison_raw', 'incident') }}
)
select
    id              as incident_id,
    colis_id,
    type_incident,
    priorite,
    description,
    signale_le::date as date_incident,
    statut
from incidents
order by signale_le desc