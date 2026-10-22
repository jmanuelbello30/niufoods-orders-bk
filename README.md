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

El receptor local descrito más abajo acepta HTTP POST en esas tres rutas.
Ejecutar los seeds no envía solicitudes.

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

## Receptor de tienda simulada

Es un proceso Rack/Puma independiente: no inicia Rails ni consulta su base de
datos. Usa las dependencias existentes, sin gemas adicionales.

### Inicio y detención

Desde la raíz del proyecto, iniciar en primer plano:

```sh
~/.local/bin/mise exec -- bundle exec ruby script/store_receiver.rb
```

Escucha solamente en loopback, `127.0.0.1:4567` (`localhost:4567`). Detener con
`Ctrl+C`. Para iniciarlo en segundo plano y detener exactamente ese proceso
desde la misma terminal:

```sh
~/.local/bin/mise exec -- bundle exec ruby script/store_receiver.rb &
receiver_pid=$!
```

Cuando termines, en esa misma terminal:

```sh
kill -TERM "$receiver_pid"
wait "$receiver_pid"
```

La detención mediante `SIGINT` o `SIGTERM` espera a que terminen las solicitudes
en curso. No se crean archivos PID ni datos persistentes.

### Simulación

| Variable | Valor predeterminado | Comportamiento |
| --- | --- | --- |
| `STORE_PORT` | `4567` | Puerto local, entre 1 y 65535. |
| `STORE_MODE` | `success` | `success`, `error` o `delay`. |
| `STORE_DELAY_SECONDS` | `6` | Demora finita y no negativa, en segundos; solo se aplica en `delay`. |

```sh
STORE_MODE=error ~/.local/bin/mise exec -- bundle exec ruby script/store_receiver.rb
STORE_MODE=delay STORE_DELAY_SECONDS=6 ~/.local/bin/mise exec -- bundle exec ruby script/store_receiver.rb
STORE_PORT=4568 ~/.local/bin/mise exec -- bundle exec ruby script/store_receiver.rb
```

`error` responde HTTP 503 sin aceptar. En `delay`, la orden se acepta **después**
de esperar. Si el emisor alcanza su timeout, el receptor puede aceptarla luego;
un reenvío posterior devuelve una confirmación de duplicado sin volver a esperar.
Cambiar el puerto requiere ajustar el destino del emisor; los seeds usan 4567.

### Payload y confirmación

El contrato completo para el futuro emisor está en
[`docs/alcance.md`](docs/alcance.md#contrato-del-receptor-simulado). El receptor
solo comprueba la estructura mínima y los identificadores; no recalcula precios
ni totales y no comprueba la existencia de productos en Rails.

Ejemplo con datos ficticios, independiente de las órdenes de la base:

```sh
curl -i http://localhost:4567/restaurants/PROV/orders \
  -H 'Content-Type: application/json' \
  --data '{
    "order_id": 9001,
    "restaurant_id": 1,
    "order_type": "pickup",
    "customer": { "name": "Test Customer", "phone": "+56000000000" },
    "delivery_address": null,
    "total_amount": 17980,
    "items": [ { "product_id": 1, "quantity": 2, "unit_price": 8990 } ]
  }'
```

Respuesta HTTP 200 con `Content-Type: application/json`:

```json
{
  "data": {
    "accepted": true,
    "order_id": 9001,
    "restaurant_id": 1,
    "duplicate": false
  }
}
```

Al repetir el mismo envío al mismo restaurante, devuelve HTTP 200 con
`duplicate: true`, sin una segunda aceptación. El mismo `order_id` en otro
restaurante tiene una clave distinta. La comprobación y el registro están
protegidos con un mutex, incluso ante solicitudes concurrentes.

La memoria de IDs es local a un solo proceso, crece con las recepciones y se
pierde al reiniciar. No existe persistencia, coordinación entre procesos ni
autenticación: es un simulador local, no un receptor de producción. La consola
solo registra restaurante, identificador válido y resultado, nunca cliente,
teléfono, dirección ni payload completo.

Las pruebas del receptor pueden ejecutarse sin Rails ni PostgreSQL:

```sh
~/.local/bin/mise exec -- bundle exec ruby -Itest test/lib/store_receiver_test.rb
```

Este incremento no implementa el emisor HTTP ni cambia estados de órdenes de
Rails. `POST /api/v1/orders` sigue creando órdenes en `pending` sin despacharlas.
