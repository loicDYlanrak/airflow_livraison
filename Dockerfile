FROM apache/airflow:2.10.0

USER root

RUN apt-get update && apt-get install -y \
    postgresql-client \
    libpq-dev \
    gcc \
    && apt-get clean

USER airflow

# Installation des dépendances Python
RUN pip install pandas sqlalchemy psycopg2-binary

# Installation de dbt-postgres
RUN pip install dbt-postgres==1.7.0

# Installation du provider PostgreSQL pour Airflow
RUN pip install apache-airflow-providers-postgres