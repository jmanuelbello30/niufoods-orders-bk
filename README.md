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

## Creación de órdenes

Con el servidor iniciado (`bin/rails server`) y el catálogo cargado,
`POST /api/v1/orders` recibe JSON directamente en la raíz, sin envoltura `order`.
Los ejemplos usan datos ficticios y los IDs del catálogo de referencia.

### Orden aceptada

```sh
curl -i http://localhost:3000/api/v1/orders \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data '{
    "restaurant_id": 2,
    "order_type": "delivery",
    "customer": { "name": "Test Customer", "phone": "+56000000000" },
    "delivery_address": "Test Street 123",
    "items": [
      { "product_id": 1, "quantity": 2 },
      { "product_id": 5, "quantity": 1 }
    ]
  }'
```

Responde HTTP 201 con `data`, que incluye `id`, `restaurant_id`, `order_type`,
`total_amount`, `client_total_amount`, `dispatch_status` y `created_at`.
El total de este ejemplo es 22470 CLP. `client_total_amount` es opcional y se
devuelve como `null` si no se informa o se envía `null`.

La orden se crea en estado `pending`: este incremento no realiza despachos.
El envío al receptor se implementará después.

### Diferencia de totales

```sh
curl -i http://localhost:3000/api/v1/orders \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data '{
    "restaurant_id": 2,
    "order_type": "delivery",
    "customer": { "name": "Test Customer", "phone": "+56000000000" },
    "delivery_address": "Test Street 123",
    "items": [
      { "product_id": 1, "quantity": 2 },
      { "product_id": 5, "quantity": 1 }
    ],
    "client_total_amount": 22000
  }'
```

Responde HTTP 422 sin guardar la orden ni sus ítems:

```json
{
  "errors": [
    {
      "field": "client_total_amount",
      "code": "total_mismatch",
      "message": "Declared total 22000 CLP does not match calculated total 22470 CLP"
    }
  ]
}
```

Los errores de estructura usan `invalid_structure`. Los demás errores de
validación también responden HTTP 422 bajo `errors`, con `field`, `code` y
`message`. Un cuerpo JSON malformado responde HTTP 400 con `invalid_json`,
sin detalles internos de la excepción.
