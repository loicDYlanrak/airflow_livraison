from airflow import DAG
from airflow.operators.python import PythonOperator
from datetime import datetime

import pandas as pd
from sqlalchemy import create_engine

def load_csv():

    df = pd.read_csv('/opt/airflow/data/warehouse.csv')

    engine = create_engine(
        "postgresql+psycopg2://airflow:airflow@postgres/warehouse_db"
    )

    df.to_sql(
        'warehouse',
        engine,
        if_exists='append',
        index=False
    )

    print(f"{len(df)} lignes insérées")

with DAG(
    dag_id='load_csv_to_warehouse',
    start_date=datetime(2025,1,1),
    schedule=None,
    catchup=False
) as dag:

    task = PythonOperator(
        task_id='load_csv',
        python_callable=load_csv
    )