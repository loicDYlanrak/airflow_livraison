@echo off

echo Construction des images...
docker-compose build

echo Demarrage des conteneurs...
docker-compose up -d
echo.
echo Airflow disponible sur :
echo http://localhost:8080
echo.
echo Login : admin
echo Password : admin

pause