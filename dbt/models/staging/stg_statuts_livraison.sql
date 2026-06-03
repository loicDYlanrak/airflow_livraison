-- Staging : historique des statuts de chaque colis
with source as (
    select * from {{ source('livraison_raw', 'statut_livraison') }}
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
