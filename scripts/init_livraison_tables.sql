-- Tables pour le workflow de livraison
CREATE TABLE IF NOT EXISTS commande (
    id SERIAL PRIMARY KEY,
    client_id INTEGER,
    date_commande TIMESTAMP DEFAULT NOW(),
    statut VARCHAR(50) DEFAULT 'NOUVELLE',
    montant_total DECIMAL(10,2),
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS colis (
    id SERIAL PRIMARY KEY,
    commande_id INTEGER REFERENCES commande(id),
    tournee_id INTEGER,
    reference_tracking VARCHAR(100) UNIQUE,
    poids_kg DECIMAL(6,2),
    statut_actuel VARCHAR(50),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS statut_livraison (
    id SERIAL PRIMARY KEY,
    colis_id INTEGER REFERENCES colis(id),
    statut VARCHAR(50),
    horodatage TIMESTAMP DEFAULT NOW(),
    localisation VARCHAR(255)
);

-- Données de test
INSERT INTO commande (client_id, statut, montant_total) VALUES
(101, 'NOUVELLE', 150.00),
(102, 'validee', 89.99),
(103, 'livree', 210.50)
ON CONFLICT (id) DO NOTHING;

INSERT INTO colis (commande_id, reference_tracking, poids_kg, statut_actuel) VALUES
(1, 'TRK001', 2.5, 'preparation'),
(2, 'TRK002', 1.2, 'expedie'),
(3, 'TRK003', 3.0, 'livre')
ON CONFLICT (id) DO NOTHING;

INSERT INTO statut_livraison (colis_id, statut, localisation) VALUES
(1, 'NOUVELLE', 'Entrepôt A'),
(1, 'preparation', 'Entrepôt A'),
(2, 'expedie', 'Centre de tri'),
(3, 'livre', 'Client')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS incident (
    id SERIAL PRIMARY KEY,
    colis_id INTEGER REFERENCES colis(id),
    type_incident VARCHAR(100),
    priorite VARCHAR(50),
    description TEXT,
    signale_le TIMESTAMP DEFAULT NOW(),
    statut VARCHAR(50) DEFAULT 'ouvert'
);

INSERT INTO incident (colis_id, type_incident, priorite, description, statut) VALUES
(1, 'retard', 'haute', 'Colis non livré dans les délais', 'ouvert'),
(2, 'dommage', 'moyenne', 'Emballage endommagé', 'en_cours'),
(3, 'erreur_adresse', 'basse', 'Adresse incorrecte', 'resolu');