from airflow import settings
from airflow.models import Connection

conn = Connection(
    conn_id='postgres_livraison',
    conn_type='postgres',
    host='postgres-livraison',
    login='livraison',
    password='livraison_pass',
    port=5432,
    schema='livraison_db'
)

session = settings.Session()
if not session.query(Connection).filter(Connection.conn_id == conn.conn_id).first():
    session.add(conn)
    session.commit()
    print("Connection créée")
else:
    print("Connection existe déjà")