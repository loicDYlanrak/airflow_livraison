
  create view "livraison_db"."staging"."stg_commandes__dbt_tmp"
    
    
  as (
    -- Staging : nettoyage et typage de la table source COMMANDE
with source as (
    select * from "livraison_db"."public"."commande"
),
renamed as (
    select
        id                          as commande_id,
        client_id,
        date_commande::timestamp    as commande_ts,
        lower(trim(statut))         as statut,
        montant_total::numeric(10,2) as montant_total,
        created_at,
        updated_at
    from source
    where id is not null
)
select * from renamed
  );