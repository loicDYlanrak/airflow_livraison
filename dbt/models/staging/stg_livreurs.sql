-- Staging : nettoyage de la table LIVREUR
with source as (
    select * from {{ source('livraison_raw', 'livreur') }}
),
renamed as (
    select
        id                          as livreur_id,
        nom,
        prenom,
        telephone,
        lower(zone_secteur)         as zone_secteur,
        lower(statut)               as statut,
        created_at
    from source
    where id is not null
)
select * from renamed