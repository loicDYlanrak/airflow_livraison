-- Staging : nettoyage de la table COLIS
with source as (
    select * from {{ source('livraison_raw', 'colis') }}
),
renamed as (
    select
        id                       as colis_id,
        commande_id,
        tournee_id,
        reference_tracking,
        poids_kg::numeric(6,2)   as poids_kg,
        lower(statut_actuel)     as statut_actuel,
        created_at
    from source
    where id is not null
)
select * from renamed
