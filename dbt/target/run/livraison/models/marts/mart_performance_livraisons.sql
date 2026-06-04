
  
    

  create  table "livraison_db"."marts"."mart_performance_livraisons__dbt_tmp"
  
  
    as
  
  (
    -- Mart analytique : KPI de performance des livraisons
-- Utilise par le DAG rapport_journalier et les dashboards
with livraisons as (
    select * from "livraison_db"."intermediate"."int_livraisons_enrichies"
),
agregats as (
    select
        date_trunc('day', commande_ts)::date            as jour,
        count(*)                                        as nb_livraisons_total,
        count(*) filter (where dernier_statut = 'livre') as nb_livrees,
        count(*) filter (where dernier_statut = 'echec') as nb_echecs,
        round(
            count(*) filter (where dernier_statut = 'livre')
            * 100.0 / nullif(count(*), 0), 2
        )                                               as taux_succes_pct,
        avg(poids_kg)                                   as poids_moyen_kg,
        sum(montant_total)                              as ca_journalier
    from livraisons
    group by 1
)
select * from agregats order by jour desc
  );
  