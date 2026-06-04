-- Mart analytique : KPI de performance des livraisons
-- Sources : commandes + statuts uniquement (pas de colis)
with commandes as (
    select * from {{ ref('stg_commandes') }}
),
statuts as (
    select distinct on (colis_id)
        colis_id,
        statut          as dernier_statut,
        statut_ts       as derniere_maj
    from {{ ref('stg_statuts_livraison') }}
    order by colis_id, statut_ts desc
),
agregats as (
    select
        date_trunc('day', c.commande_ts)::date              as jour,
        count(*)                                            as nb_commandes_total,
        count(*) filter (where s.dernier_statut = 'livre')  as nb_livrees,
        count(*) filter (where s.dernier_statut = 'echec')  as nb_echecs,
        round(
            count(*) filter (where s.dernier_statut = 'livre')
            * 100.0 / nullif(count(*), 0), 2
        )                                                   as taux_succes_pct,
        sum(c.montant_total)                                as ca_journalier
    from commandes c
    left join statuts s on s.colis_id = c.commande_id  -- lien indirect provisoire
    group by 1
)
select * from agregats order by jour desc