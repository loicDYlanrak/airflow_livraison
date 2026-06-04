-- Staging : historique des statuts de chaque colis
with source as (
    select * from "livraison_db"."public"."statut_livraison"
),
renamed as (
    select
        id                    as statut_id,
        colis_id,
        lower(statut)         as statut,
        horodatage::timestamp as statut_ts,
        localisation
    from source
)
select * from renamed