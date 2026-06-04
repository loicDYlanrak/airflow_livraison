FROM apache/airflow:2.10.0

USER root

RUN apt-get update && apt-get install -y \
    postgresql-client \
    libpq-dev \
    gcc \
    && apt-get clean

USER airflow

RUN pip install pandas sqlalchemy psycopg2-binary

RUN pip install dbt-postgres==1.7.0

RUN pip install apache-airflow-providers-postgres