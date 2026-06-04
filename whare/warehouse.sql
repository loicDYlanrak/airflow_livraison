-- ============================================================
--  DATA WAREHOUSE LIVRAISON — SCHÉMA EN ÉTOILE
--  Généré à partir des sources :
--    colis.xlsx | retour.csv | facture.xml | warehouse.csv
--    tournee.json | notification.json | clients.txt
--    init_livraison_tables.sql
--
--  Modèle : schéma en étoile avec 2 tables de faits et 7 dimensions
--
--    FAITS
--      fait_livraison          -- grain : 1 ligne par expédition de colis
--      fait_retour             -- grain : 1 ligne par retour de colis
--
--    DIMENSIONS
--      dim_temps               -- dates (même structure que modèle de référence)
--      dim_client              -- destinataires / clients
--      dim_livreur             -- livreurs (source tournee.json + livreur OLTP)
--      dim_vehicule            -- véhicules affectés aux tournées
--      dim_colis               -- descriptif du colis (type, fragile, poids…)
--      dim_entrepot            -- entrepôt de départ
--      dim_geo                 -- géographie ville / province / pays
-- ============================================================

-- ============================================================
--  NETTOYAGE
-- ============================================================
DROP TABLE IF EXISTS warehouse.fait_retour                CASCADE;
DROP TABLE IF EXISTS warehouse.fait_livraison             CASCADE;
DROP TABLE IF EXISTS warehouse.dim_temps                  CASCADE;
DROP TABLE IF EXISTS warehouse.dim_client                 CASCADE;
DROP TABLE IF EXISTS warehouse.dim_livreur                CASCADE;
DROP TABLE IF EXISTS warehouse.dim_vehicule               CASCADE;
DROP TABLE IF EXISTS warehouse.dim_colis                  CASCADE;
DROP TABLE IF EXISTS warehouse.dim_entrepot               CASCADE;
DROP TABLE IF EXISTS warehouse.dim_geo                    CASCADE;


-- ============================================================
--  DIMENSIONS
-- ============================================================

-- ------------------------------------------------------------
--  DIM_TEMPS
--  Source : toutes les dates présentes dans les sources
--  (date_expedition, date_livraison_prevue, date_retour,
--   date_facture, date_notification, date_tournee)
-- ------------------------------------------------------------
CREATE TABLE warehouse.dim_temps (
    id_dim_temps        SERIAL          PRIMARY KEY,
    date_complete       DATE            NOT NULL,
    annee               SMALLINT        NOT NULL,
    trimestre           SMALLINT        NOT NULL,   -- 1 à 4
    mois                SMALLINT        NOT NULL,   -- 1 à 12
    lib_mois            VARCHAR(20)     NOT NULL,
    semaine             SMALLINT        NOT NULL,   -- numéro ISO
    jour                SMALLINT        NOT NULL,   -- jour du mois
    lib_jour            VARCHAR(20)     NOT NULL,
    est_weekend         BOOLEAN         NOT NULL DEFAULT FALSE
);

CREATE UNIQUE INDEX uq_dim_temps_date ON warehouse.dim_temps (date_complete);


-- ------------------------------------------------------------
--  DIM_CLIENT
--  Source : clients.txt  +  champ id_client dans les autres fichiers
-- ------------------------------------------------------------
CREATE TABLE warehouse.dim_client (
    id_dim_client       SERIAL          PRIMARY KEY,
    id_source           INT,                        -- id_client opérationnel
    nom                 VARCHAR(100),
    prenom              VARCHAR(100),
    adresse             VARCHAR(200),
    ville               VARCHAR(80),
    province            VARCHAR(80),
    pays                VARCHAR(50),
    telephone           VARCHAR(30),
    email               VARCHAR(120),
    segment             VARCHAR(50)
);


-- ------------------------------------------------------------
--  DIM_LIVREUR
--  Source : tournee.json → livreur{}  +  table livreur OLTP
-- ------------------------------------------------------------
CREATE TABLE warehouse.dim_livreur (
    id_dim_livreur      SERIAL          PRIMARY KEY,
    id_source           INT,                        -- id_livreur opérationnel
    nom                 VARCHAR(100),
    prenom              VARCHAR(100),
    nom_complet         VARCHAR(200),
    telephone           VARCHAR(30),
    zone_secteur        VARCHAR(80),
    statut              VARCHAR(30)     DEFAULT 'disponible'
);


-- ------------------------------------------------------------
--  DIM_VEHICULE
--  Source : tournee.json → vehicule{}
-- ------------------------------------------------------------
CREATE TABLE warehouse.dim_vehicule (
    id_dim_vehicule     SERIAL          PRIMARY KEY,
    id_source           INT,                        -- id_vehicule opérationnel
    immatriculation     VARCHAR(30),
    type_vehicule       VARCHAR(50),
    capacite_kg         NUMERIC(8,2)
);


-- ------------------------------------------------------------
--  DIM_COLIS
--  Source : colis.xlsx
--  Attributs descriptifs uniquement (pas de métriques)
-- ------------------------------------------------------------
CREATE TABLE warehouse.dim_colis (
    id_dim_colis        SERIAL          PRIMARY KEY,
    id_source           INT,                        -- id_colis opérationnel
    code_suivi          VARCHAR(30),
    type_colis          VARCHAR(50),                -- Electronique, Alimentaire…
    poids_kg            NUMERIC(8,3),
    fragile             BOOLEAN         DEFAULT FALSE,
    expediteur          VARCHAR(150),
    destinataire        VARCHAR(150)
);


-- ------------------------------------------------------------
--  DIM_ENTREPOT
--  Source : colis.xlsx → colonne "entrepot"
-- ------------------------------------------------------------
CREATE TABLE warehouse.dim_entrepot (
    id_dim_entrepot     SERIAL          PRIMARY KEY,
    code_entrepot       VARCHAR(20)     NOT NULL,   -- ENT-A, ENT-B, ENT-C…
    nom_entrepot        VARCHAR(100),
    ville               VARCHAR(80),
    pays                VARCHAR(50)     DEFAULT 'Madagascar'
);


-- ------------------------------------------------------------
--  DIM_GEO
--  Source : colis.xlsx (ville_depart / ville_arrivee)
--           tournee.json (villes_etapes)
-- ------------------------------------------------------------
CREATE TABLE warehouse.dim_geo (
    id_dim_geo          SERIAL          PRIMARY KEY,
    ville               VARCHAR(80),
    province            VARCHAR(80),
    pays                VARCHAR(50)     DEFAULT 'Madagascar'
);

CREATE UNIQUE INDEX uq_dim_geo_ville ON warehouse.dim_geo (ville, pays);

-- ============================================================
--  TABLES DE FAITS
-- ============================================================

-- ------------------------------------------------------------
--  FAIT_LIVRAISON
--  Grain : 1 ligne = 1 expédition de colis (1 colis traité lors
--          d'une tournée)
--
--  Métriques :
--    frais_livraison         — montant facturé au client pour la livraison
--    montant_ht              — montant HT de la facture liée
--    tva                     — TVA de la facture
--    montant_ttc             — montant TTC
--    poids_kg                — poids du colis
--    km_parcourus_part       — part des km de la tournée attribuée au colis
--    carburant_litres_part   — part carburant attribuée au colis
--    frais_tournee_part      — part des frais de tournée attribuée
--    delai_livraison_jours   — nb de jours entre expédition et livraison réelle
--    livraison_dans_delai    — flag booléen (livré avant ou à la date prévue)
-- ------------------------------------------------------------
CREATE TABLE warehouse.fait_livraison (
    id_fait_livraison       SERIAL          PRIMARY KEY,

    -- Clés étrangères dimensions
    id_dim_temps_expedition INT             NOT NULL
                            REFERENCES warehouse.dim_temps(id_dim_temps),
    id_dim_temps_livraison  INT
                            REFERENCES warehouse.dim_temps(id_dim_temps),   -- NULL si pas encore livré
    id_dim_client           INT             NOT NULL
                            REFERENCES warehouse.dim_client(id_dim_client),
    id_dim_livreur          INT
                            REFERENCES warehouse.dim_livreur(id_dim_livreur),
    id_dim_vehicule         INT
                            REFERENCES warehouse.dim_vehicule(id_dim_vehicule),
    id_dim_colis            INT             NOT NULL
                            REFERENCES warehouse.dim_colis(id_dim_colis),
    id_dim_entrepot         INT
                            REFERENCES warehouse.dim_entrepot(id_dim_entrepot),
    id_dim_geo_depart       INT
                            REFERENCES warehouse.dim_geo(id_dim_geo),
    id_dim_geo_arrivee      INT
                            REFERENCES warehouse.dim_geo(id_dim_geo),

    -- Dégénérée (clé sans dimension propre)
    id_tournee              INT,                                    -- tournee.json → id_tournee
    id_facture              INT,                                    -- facture.xml  → id_facture
    statut_livraison        VARCHAR(30),                           -- En transit / Livré / En préparation…
    mode_paiement           VARCHAR(40),                           -- facture.xml  → mode_paiement

    -- Métriques financières (facture.xml)
    montant_ht              NUMERIC(12,2),
    tva                     NUMERIC(12,2),
    montant_ttc             NUMERIC(12,2),

    -- Métriques logistiques (colis.xlsx)
    frais_livraison         NUMERIC(12,2),
    poids_kg                NUMERIC(8,3),

    -- Métriques tournée (tournee.json — répartis au prorata)
    km_parcourus_part       NUMERIC(8,2),
    carburant_litres_part   NUMERIC(8,3),
    frais_tournee_part      NUMERIC(10,2),

    -- Métriques délai
    delai_livraison_jours   INT,
    livraison_dans_delai    BOOLEAN         DEFAULT NULL
);

-- Index sur les FK les plus sollicitées
CREATE INDEX idx_fait_liv_temps_exp    ON warehouse.fait_livraison (id_dim_temps_expedition);
CREATE INDEX idx_fait_liv_temps_liv    ON warehouse.fait_livraison (id_dim_temps_livraison);
CREATE INDEX idx_fait_liv_client       ON warehouse.fait_livraison (id_dim_client);
CREATE INDEX idx_fait_liv_livreur      ON warehouse.fait_livraison (id_dim_livreur);
CREATE INDEX idx_fait_liv_colis        ON warehouse.fait_livraison (id_dim_colis);
CREATE INDEX idx_fait_liv_geo_dep      ON warehouse.fait_livraison (id_dim_geo_depart);
CREATE INDEX idx_fait_liv_geo_arr      ON warehouse.fait_livraison (id_dim_geo_arrivee);
CREATE INDEX idx_fait_liv_entrepot     ON warehouse.fait_livraison (id_dim_entrepot);
CREATE INDEX idx_fait_liv_statut       ON warehouse.fait_livraison (statut_livraison);


-- ------------------------------------------------------------
--  FAIT_RETOUR
--  Grain : 1 ligne = 1 retour enregistré (retour.csv)
--
--  Métriques :
--    montant_ttc_retourne    — montant TTC remboursé (lié à la facture d'origine)
--    frais_retour            — frais logistiques du retour
--    delai_retour_jours      — nb jours entre livraison et date de retour
-- ------------------------------------------------------------
CREATE TABLE warehouse.fait_retour (
    id_fait_retour          SERIAL          PRIMARY KEY,

    -- Clés étrangères dimensions
    id_dim_temps_retour     INT             NOT NULL
                            REFERENCES warehouse.dim_temps(id_dim_temps),
    id_dim_client           INT             NOT NULL
                            REFERENCES warehouse.dim_client(id_dim_client),
    id_dim_colis            INT             NOT NULL
                            REFERENCES warehouse.dim_colis(id_dim_colis),
    id_dim_geo_retour       INT
                            REFERENCES warehouse.dim_geo(id_dim_geo),

    -- Lien vers le fait de livraison d'origine
    id_fait_livraison       INT
                            REFERENCES warehouse.fait_livraison(id_fait_livraison),

    -- Dégénérées
    id_retour               INT,                                    -- retour.csv → id_retour
    motif_retour            VARCHAR(100),                          -- retour.csv → motif
    commentaire             TEXT,

    -- Métriques
    montant_ttc_retourne    NUMERIC(12,2),
    frais_retour            NUMERIC(10,2),
    delai_retour_jours      INT
);

CREATE INDEX idx_fait_ret_temps        ON warehouse.fait_retour (id_dim_temps_retour);
CREATE INDEX idx_fait_ret_client       ON warehouse.fait_retour (id_dim_client);
CREATE INDEX idx_fait_ret_colis        ON warehouse.fait_retour (id_dim_colis);
CREATE INDEX idx_fait_ret_motif        ON warehouse.fait_retour (motif_retour);
CREATE INDEX idx_fait_ret_livraison    ON warehouse.fait_retour (id_fait_livraison);


-- ============================================================
--  DONNÉES DE RÉFÉRENCE — DIMENSIONS (exemples issus des sources)
-- ============================================================

-- ════ DIM_ENTREPOT ════
INSERT INTO warehouse.dim_entrepot (code_entrepot, nom_entrepot, ville) VALUES
    ('ENT-A', 'Entrepôt principal A',   'Antananarivo'),
    ('ENT-B', 'Entrepôt secondaire B',  'Toamasina'),
    ('ENT-C', 'Entrepôt régional C',    'Fianarantsoa');

-- ════ DIM_GEO (villes Madagascar issues de colis.xlsx + tournee.json) ════
INSERT INTO warehouse.dim_geo (ville, province, pays) VALUES
    ('Antananarivo', 'Analamanga',       'Madagascar'),
    ('Toamasina',    'Atsinanana',       'Madagascar'),
    ('Antsirabe',    'Vakinankaratra',   'Madagascar'),
    ('Fianarantsoa', 'Haute Matsiatra',  'Madagascar'),
    ('Mahajanga',    'Boeny',            'Madagascar'),
    ('Toliara',      'Atsimo-Andrefana', 'Madagascar');

-- ════ DIM_TEMPS (dates clés issues des sources — 2026-05-26 à 2026-06-11) ════
INSERT INTO warehouse.dim_temps (date_complete, annee, trimestre, mois, lib_mois, semaine, jour, lib_jour, est_weekend) VALUES
    ('2026-05-26', 2026, 2, 5, 'Mai',   22, 26, 'Mardi',    FALSE),
    ('2026-05-27', 2026, 2, 5, 'Mai',   22, 27, 'Mercredi', FALSE),
    ('2026-05-28', 2026, 2, 5, 'Mai',   22, 28, 'Jeudi',    FALSE),
    ('2026-05-29', 2026, 2, 5, 'Mai',   22, 29, 'Vendredi', FALSE),
    ('2026-05-30', 2026, 2, 5, 'Mai',   22, 30, 'Samedi',   TRUE),
    ('2026-05-31', 2026, 2, 5, 'Mai',   22, 31, 'Dimanche', TRUE),
    ('2026-06-01', 2026, 2, 6, 'Juin',  23,  1, 'Lundi',    FALSE),
    ('2026-06-02', 2026, 2, 6, 'Juin',  23,  2, 'Mardi',    FALSE),
    ('2026-06-03', 2026, 2, 6, 'Juin',  23,  3, 'Mercredi', FALSE),
    ('2026-06-04', 2026, 2, 6, 'Juin',  23,  4, 'Jeudi',    FALSE),
    ('2026-06-05', 2026, 2, 6, 'Juin',  23,  5, 'Vendredi', FALSE),
    ('2026-06-06', 2026, 2, 6, 'Juin',  23,  6, 'Samedi',   TRUE),
    ('2026-06-07', 2026, 2, 6, 'Juin',  23,  7, 'Dimanche', TRUE),
    ('2026-06-08', 2026, 2, 6, 'Juin',  23,  8, 'Lundi',    FALSE),
    ('2026-06-09', 2026, 2, 6, 'Juin',  23,  9, 'Mardi',    FALSE),
    ('2026-06-10', 2026, 2, 6, 'Juin',  23, 10, 'Mercredi', FALSE),
    ('2026-06-11', 2026, 2, 6, 'Juin',  23, 11, 'Jeudi',    FALSE);

-- ════ DIM_VEHICULE (source : tournee.json) ════
INSERT INTO warehouse.dim_vehicule (id_source, immatriculation, type_vehicule, capacite_kg) VALUES
    (1, '1001 TBA', 'Moto', 50.00),
    (2, '1002 TBA', 'Moto', 50.00),
    (3, '1003 TBA', 'Utilitaire léger', 500.00),
    (4, '1004 TBA', 'Camionnette', 800.00),
    (6, '1005 TBA', 'Camionnette', 850.00),
    (7, '1006 TBA', 'Fourgon', 1200.00),
    (8, '1007 TBA', 'Camion moyen', 2500.00),
    (9, '1008 TBA', 'Camion lourd', 5000.00),
    (10, '1009 TBA', 'Vélo cargo', 80.00),
    (11, '1010 TBA', 'Utilitaire léger', 450.00);

-- ════ DIM_LIVREUR (source : tournee.json) ════
INSERT INTO warehouse.dim_livreur (id_source, nom, prenom, nom_complet, telephone, zone_secteur, statut) VALUES
    (1, 'Rakotoarisoa', 'Hery', 'Hery Rakotoarisoa', '0341122334', 'Antananarivo Centre', 'actif'),
    (2, 'Ramanandraibe', 'Tiana', 'Tiana Ramanandraibe', '0342233445', 'Antananarivo Nord', 'actif'),
    (3, 'Razafindramboa', 'Miora', 'Miora Razafindramboa', '0343344556', 'Antananarivo Sud', 'actif'),
    (4, 'Randrianasolo', 'Feno', 'Feno Randrianasolo', '0344455667', 'Toamasina', 'actif'),
    (5, 'Raharison', 'Njaka', 'Njaka Raharison', '0345566778', 'Toamasina', 'en_conge'),
    (6, 'Ranaivoarisoa', 'Lova', 'Lova Ranaivoarisoa', '0346677889', 'Fianarantsoa', 'actif'),
    (7, 'Rakotomamonjy', 'Soa', 'Soa Rakotomamonjy', '0347788990', 'Fianarantsoa', 'actif'),
    (8, 'Randriamampionona', 'Aina', 'Aina Randriamampionona', '0348899001', 'Mahajanga', 'actif'),
    (9, 'Raveloson', 'Tahina', 'Tahina Raveloson', '0349900112', 'Mahajanga', 'actif'),
    (10, 'Rakotondrabe', 'Mamy', 'Mamy Rakotondrabe', '0350011223', 'Antsirabe', 'actif'),
    (11, 'Rasoanaivo', 'Nirina', 'Nirina Rasoanaivo', '0351122334', 'Antsirabe', 'actif'),
    (12, 'Rakotovao', 'Haja', 'Haja Rakotovao', '0352233445', 'Toliara', 'actif'),
    (13, 'Randrianarison', 'Toky', 'Toky Randrianarison', '0353344556', 'Toliara', 'actif'),
    (14, 'Ramanantenasoa', 'Jean', 'Jean Ramanantenasoa', '0354455667', 'Antananarivo Est', 'en_formation'),
    (15, 'Razafimandimby', 'Rija', 'Rija Razafimandimby', '0355566778', 'Antananarivo Ouest', 'actif');

-- ════ DIM_CLIENT (source : clients.txt — extrait 6 lignes) ════
INSERT INTO warehouse.dim_client (id_source, nom, prenom, adresse, ville, province, pays, telephone, email, segment) VALUES
    (1,  'Richard',  'Camille', '148 avenue Foch',      'Lille',            'Hauts-de-France',        'France', '0351177222', 'richard.camille@entreprise1.fr',  'TPE'),
    (2,  'Fontaine', 'Emma',    '61 allée des Roses',   'Montpellier',      'Occitanie',              'France', '0150000149', 'fontaine.emma@entreprise2.fr',    'TPE'),
    (3,  'Petit',    'Antoine', '146 rue du Commerce',  'Montpellier',      'Occitanie',              'France', '0216962963', 'petit.antoine@entreprise3.fr',    'Grand Compte'),
    (4,  'Laurent',  'David',   '612 allée des Roses',  'Bordeaux',         'Nouvelle-Aquitaine',     'France', '0961680358', 'laurent.david@entreprise4.fr',    'PME'),
    (5,  'Michel',   'Marie',   '326 rue du Commerce',  'Clermont-Ferrand', 'Auvergne-Rhône-Alpes',   'France', '0813879756', 'michel.marie@entreprise5.fr',     'TPE'),
    (6,  'Lambert',  'Julie',   '936 rue de la Paix',   'Lille',            'Hauts-de-France',        'France', '0243059986', 'lambert.julie@entreprise6.fr',    'Education'),
    -- Clients Madagascar (issus de colis.xlsx)
    (12, 'Rakoto',   'Jean',    NULL,                   'Antananarivo',     NULL,                     'Madagascar', NULL, NULL, NULL),
    (25, 'Rasoanaivo','Mia',    NULL,                   'Mahajanga',        NULL,                     'Madagascar', NULL, NULL, NULL),
    (45, 'Boyer',    'Thomas',  NULL,                   'Montpellier',      'Occitanie',              'France', NULL, NULL, NULL),
    (78, 'Lambert',  'Christophe',NULL,                 'Nantes',           'Pays de la Loire',       'France', NULL, NULL, NULL),
    (102,'Laurent',  'Christophe',NULL,                 'Nantes',           'Pays de la Loire',       'France', NULL, NULL, NULL),
    (140,'Michel',   'Pierre',  NULL,                   'Le Havre',         'Normandie',              'France', NULL, NULL, NULL);

-- ════ DIM_COLIS (source : colis.xlsx — 20 lignes) ════
INSERT INTO warehouse.dim_colis (id_source, code_suivi, type_colis, poids_kg, fragile, expediteur, destinataire) VALUES
    ( 1, 'MG0001', 'Electronique',  2.50,  TRUE,  'Tech Mada',      'Rakoto Jean'),
    ( 2, 'MG0002', 'Vetements',     1.20,  FALSE, 'Shop Plus',      'Rasoanaivo Mia'),
    ( 3, 'MG0003', 'Alimentaire',   5.00,  FALSE, 'Mada Market',    'Andry Solo'),
    ( 4, 'MG0004', 'Materiel',     12.80,  TRUE,  'Solar Energy',   'Rija Paul'),
    ( 5, 'MG0005', 'Documents',     0.80,  FALSE, 'Pharma One',     'Naina Kanto'),
    ( 6, 'MG0006', 'Fournitures',   7.30,  FALSE, 'Espace Bureau',  'Hery Toky'),
    ( 7, 'MG0007', 'Electronique',  3.10,  TRUE,  'Mada Express',   'Sarah Lova'),
    ( 8, 'MG0008', 'Materiel',     15.00,  FALSE, 'Agri Mada',      'Feno Nirina'),
    ( 9, 'MG0009', 'Vetements',     0.60,  FALSE, 'Boutique Chic',  'Miora Ando'),
    (10, 'MG0010', 'Electronique',  4.40,  TRUE,  'Digital Store',  'Tiana Harena'),
    (11, 'MG0011', 'Livres',        2.00,  FALSE, 'Mada Books',     'Zo Andry'),
    (12, 'MG0012', 'Decoration',    9.70,  TRUE,  'Home Deco',      'Aina Fara'),
    (13, 'MG0013', 'Vetements',     1.50,  FALSE, 'Fashion Hub',    'Lanto Mamy'),
    (14, 'MG0014', 'Informatique',  6.80,  TRUE,  'IT Solutions',   'Koloina Fitia'),
    (15, 'MG0015', 'Alimentaire',  11.20,  FALSE, 'Green Farm',     'Tahina Jo'),
    (16, 'MG0016', 'Pieces auto',  18.50,  TRUE,  'Auto Parts',     'Mickael R.'),
    (17, 'MG0017', 'Electronique',  2.90,  TRUE,  'Media Shop',     'Rina Soa'),
    (18, 'MG0018', 'Fournitures',   3.60,  FALSE, 'Office Pro',     'Hasina K.'),
    (19, 'MG0019', 'Telephone',     1.10,  TRUE,  'Mada Mobile',    'Fenosoa L.'),
    (20, 'MG0020', 'Divers',        8.40,  FALSE, 'Quick Delivery', 'Tokiniaina M.');

-- ============================================================
--  DONNÉES DE FAITS — FAIT_LIVRAISON (20 colis de colis.xlsx)
-- ============================================================
-- Conventions :
--   id_dim_temps_expedition  → date_expedition
--   id_dim_temps_livraison   → date_livraison_prevue si statut = Livré, NULL sinon
--   id_dim_client            → clients issus de dim_client (id_source)
--   id_dim_livreur           → 1 (Andry Rakoto, seul livreur chargé)
--   id_dim_vehicule          → 1 (1234 TBA)
--   frais_tournee_part       → total frais tournée (138 000 Ar) / 8 colis = 17 250 Ar
--   km_parcourus_part        → 286 km / 8 colis = 35.75 km
--   carburant_litres_part    → 24.5 L / 8 colis = 3.06 L

INSERT INTO warehouse.fait_livraison (
    id_dim_temps_expedition, id_dim_temps_livraison,
    id_dim_client, id_dim_livreur, id_dim_vehicule,
    id_dim_colis,  id_dim_entrepot,
    id_dim_geo_depart, id_dim_geo_arrivee,
    id_tournee, id_facture,
    statut_livraison, mode_paiement,
    montant_ht, tva, montant_ttc,
    frais_livraison, poids_kg,
    km_parcourus_part, carburant_litres_part, frais_tournee_part,
    delai_livraison_jours, livraison_dans_delai
) VALUES
-- COL0005 — facture 1001 — client 12 — Pharma One
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-05-30'),
    (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-03'),
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 12 LIMIT 1),
    1, 1,
    (SELECT id_dim_colis FROM warehouse.dim_colis WHERE id_source = 5),
    (SELECT id_dim_entrepot FROM warehouse.dim_entrepot WHERE code_entrepot = 'ENT-B'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Toamasina'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Antananarivo'),
    1001, 1001,
    'Livré', 'Mobile Money',
    35000, 7000, 42000,
    12000, 0.80,
    35.75, 3.06, 17250,
    4, TRUE
),
-- COL0008 — facture 1002 — client 45
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-01'),
    NULL,
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 45 LIMIT 1),
    1, 1,
    (SELECT id_dim_colis FROM warehouse.dim_colis WHERE id_source = 8),
    (SELECT id_dim_entrepot FROM warehouse.dim_entrepot WHERE code_entrepot = 'ENT-A'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Antsirabe'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Fianarantsoa'),
    1001, 1002,
    'En transit', 'Carte Bancaire',
    18000, 3600, 21600,
    55000, 15.00,
    35.75, 3.06, 17250,
    NULL, NULL
),
-- COL0012 — facture 1003 — client 78
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-04'),
    NULL,
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 78 LIMIT 1),
    1, 1,
    (SELECT id_dim_colis FROM warehouse.dim_colis WHERE id_source = 12),
    (SELECT id_dim_entrepot FROM warehouse.dim_entrepot WHERE code_entrepot = 'ENT-C'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Toamasina'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Toliara'),
    1001, 1003,
    'En préparation', 'Espèces',
    42000, 8400, 50400,
    40000, 9.70,
    35.75, 3.06, 17250,
    NULL, NULL
),
-- COL0017 — facture 1004 — client 102
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-04'),
    NULL,
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 102 LIMIT 1),
    1, 1,
    (SELECT id_dim_colis FROM warehouse.dim_colis WHERE id_source = 17),
    (SELECT id_dim_entrepot FROM warehouse.dim_entrepot WHERE code_entrepot = 'ENT-B'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Antananarivo'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Toliara'),
    1001, 1004,
    'En préparation', 'Virement',
    26000, 5200, 31200,
    24000, 2.90,
    35.75, 3.06, 17250,
    NULL, NULL
),
-- COL0003 — Livré — Mada Market
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-05-28'),
    (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-02'),
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 25 LIMIT 1),
    1, 1,
    (SELECT id_dim_colis FROM warehouse.dim_colis WHERE id_source = 3),
    (SELECT id_dim_entrepot FROM warehouse.dim_entrepot WHERE code_entrepot = 'ENT-C'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Fianarantsoa'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Antananarivo'),
    1001, NULL,
    'Livré', NULL,
    NULL, NULL, NULL,
    22000, 5.00,
    35.75, 3.06, 17250,
    5, TRUE
),
-- COL0009 — Livré
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-05-29'),
    (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-01'),
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 25 LIMIT 1),
    1, 1,
    (SELECT id_dim_colis FROM warehouse.dim_colis WHERE id_source = 9),
    (SELECT id_dim_entrepot FROM warehouse.dim_entrepot WHERE code_entrepot = 'ENT-C'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Antananarivo'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Toamasina'),
    1001, NULL,
    'Livré', NULL,
    NULL, NULL, NULL,
    10000, 0.60,
    35.75, 3.06, 17250,
    3, TRUE
),
-- COL0013 — Livré
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-05-27'),
    (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-05-31'),
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 25 LIMIT 1),
    1, 1,
    (SELECT id_dim_colis FROM warehouse.dim_colis WHERE id_source = 13),
    (SELECT id_dim_entrepot FROM warehouse.dim_entrepot WHERE code_entrepot = 'ENT-A'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Antananarivo'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Fianarantsoa'),
    1001, NULL,
    'Livré', NULL,
    NULL, NULL, NULL,
    13000, 1.50,
    35.75, 3.06, 17250,
    4, TRUE
),
-- COL0018 — Livré
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-05-26'),
    (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-05-30'),
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 25 LIMIT 1),
    1, 1,
    (SELECT id_dim_colis FROM warehouse.dim_colis WHERE id_source = 18),
    (SELECT id_dim_entrepot FROM warehouse.dim_entrepot WHERE code_entrepot = 'ENT-C'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Mahajanga'),
    (SELECT id_dim_geo FROM warehouse.dim_geo WHERE ville = 'Antananarivo'),
    1001, NULL,
    'Livré', NULL,
    NULL, NULL, NULL,
    17000, 3.60,
    35.75, 3.06, 17250,
    4, TRUE
);


-- ============================================================
--  DONNÉES DE FAITS — FAIT_RETOUR (source : retour.csv)
-- ============================================================
INSERT INTO warehouse.fait_retour (
    id_dim_temps_retour,
    id_dim_client,
    id_dim_colis,
    id_dim_geo_retour,
    id_fait_livraison,
    id_retour,
    motif_retour,
    commentaire,
    montant_ttc_retourne,
    frais_retour,
    delai_retour_jours
) VALUES
-- Retour 1 — colis 5 — client 12
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-03'),
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 12 LIMIT 1),
    (SELECT id_dim_colis  FROM warehouse.dim_colis  WHERE id_source  = 5  LIMIT 1),
    (SELECT id_dim_geo    FROM warehouse.dim_geo    WHERE ville = 'Antananarivo'),
    (SELECT id_fait_livraison FROM warehouse.fait_livraison WHERE id_facture = 1001 LIMIT 1),
    1, 'Colis endommagé', 'Emballage déchiré à la réception',
    42000, 5000, 0
),
-- Retour 2 — colis 8 — client 45
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-04'),
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 45 LIMIT 1),
    (SELECT id_dim_colis  FROM warehouse.dim_colis  WHERE id_source  = 8  LIMIT 1),
    (SELECT id_dim_geo    FROM warehouse.dim_geo    WHERE ville = 'Fianarantsoa'),
    NULL,
    2, 'Erreur de produit', 'Produit différent de la commande',
    21600, 5000, NULL
),
-- Retour 3 — colis 12 — client 78
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-05'),
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 78 LIMIT 1),
    (SELECT id_dim_colis  FROM warehouse.dim_colis  WHERE id_source  = 12 LIMIT 1),
    (SELECT id_dim_geo    FROM warehouse.dim_geo    WHERE ville = 'Toliara'),
    NULL,
    3, 'Refus du client', 'Le client a changé d''avis',
    50400, 5000, NULL
),
-- Retour 4 — colis 3 — client 21 (non présent en dim_client, on utilise un proxy)
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-05'),
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 3 LIMIT 1),
    (SELECT id_dim_colis  FROM warehouse.dim_colis  WHERE id_source  = 3  LIMIT 1),
    (SELECT id_dim_geo    FROM warehouse.dim_geo    WHERE ville = 'Antananarivo'),
    NULL,
    4, 'Adresse incorrecte', 'Impossible de localiser le destinataire',
    NULL, 5000, NULL
),
-- Retour 5 — colis 17 — client 102
(   (SELECT id_dim_temps FROM warehouse.dim_temps WHERE date_complete = '2026-06-06'),
    (SELECT id_dim_client FROM warehouse.dim_client WHERE id_source = 102 LIMIT 1),
    (SELECT id_dim_colis  FROM warehouse.dim_colis  WHERE id_source  = 17 LIMIT 1),
    (SELECT id_dim_geo    FROM warehouse.dim_geo    WHERE ville = 'Toliara'),
    (SELECT id_fait_livraison FROM warehouse.fait_livraison WHERE id_facture = 1004 LIMIT 1),
    5, 'Produit défectueux', 'Article non fonctionnel',
    31200, 5000, NULL
);

-- Fin du script