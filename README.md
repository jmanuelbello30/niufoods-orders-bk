# Niu Foods Orders

## Catálogo de referencia

Con las migraciones aplicadas, confirmar primero la base de desarrollo:

```sh
RAILS_ENV=development bin/rails runner 'database = ActiveRecord::Base.connection.select_value("SELECT current_database()"); puts database; abort "Unexpected database" unless database == "niufoods_orders_development"'
RAILS_ENV=development bin/rails db:seed
```

Si Ruby no está en `PATH`, anteponer `~/.local/bin/mise exec --` a `bin/rails`
en ambos comandos. Revisar la conexión antes de ejecutar; `DATABASE_URL` puede
cambiar el destino configurado.

Los seeds cargan los 10 productos (IDs 1–10) con precios enteros CLP y los
3 restaurantes (IDs 1–3) del dataset de referencia. Usan las validaciones de
los modelos y una única transacción para evitar cargas parciales.

La carga puede repetirse: los registros existentes que coinciden exactamente
se conservan, sin duplicarlos ni cambiar sus timestamps. Si un ID, SKU o código
está ocupado por un registro diferente, o los atributos de un registro de
referencia han cambiado, la carga falla con `Seed conflict` y se revierte completa.
No borra ni sobrescribe registros; los registros ajenos sin conflictos se conservan.
Al terminar, ajusta las secuencias PostgreSQL al máximo ID de cada tabla para
que las siguientes inserciones automáticas no colisionen.

### Destinos locales de despacho

| ID | Restaurante | Código | URL |
| --- | --- | --- | --- |
| 1 | Niu Foods Providencia | PROV | `http://localhost:4567/restaurants/PROV/orders` |
| 2 | Niu Foods Las Condes | LCON | `http://localhost:4567/restaurants/LCON/orders` |
| 3 | Niu Foods Ñuñoa | NUNO | `http://localhost:4567/restaurants/NUNO/orders` |

El futuro receptor deberá aceptar los despachos por HTTP POST en esas tres
rutas. El receptor no está implementado; ejecutar los seeds no envía solicitudes.
