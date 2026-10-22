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

El flujo es guardar la orden y sus ítems, confirmar la transacción, despachar
por HTTP, registrar el resultado y responder. Iniciar primero el receptor
simulado con el comando descrito más abajo para obtener `dispatch_status: "sent"`.
Si el receptor falla o su confirmación no es válida, la respuesta sigue siendo
HTTP 201, pero con `dispatch_status: "error"`: la orden y sus ítems se conservan.
Una orden rechazada con HTTP 422 no intenta el despacho.

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

El contrato completo del emisor está en
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

## Despacho HTTP síncrono

`Orders::Create` solo crea y persiste la orden. El controlador llama después a
`Orders::Dispatch`, fuera de esa transacción y sin callbacks de envío. Este
servicio exige una orden persistida, rechaza envíos dentro de una transacción
abierta y no vuelve a enviar órdenes que ya están en `sent`.

El destino es `order.restaurant.dispatch_url`. El POST envía exclusivamente los
datos recargados de la orden y sus ítems, con los precios históricos, sin leer
precios actuales del catálogo. Usa `Content-Type` y `Accept` como
`application/json`, conexión directa sin proxy de entorno y HTTP o HTTPS con
verificación de certificados.

| Configuración | Valor |
| --- | --- |
| Conexión (`open_timeout`) | 2 segundos |
| Lectura (`read_timeout`) | 5 segundos |
| Escritura (`write_timeout`) | 5 segundos |
| Reintentos automáticos (`max_retries`) | 0 |
| Redirecciones | No se siguen |

Una respuesta 2xx debe contener JSON con `data.accepted: true` y los
identificadores enteros `order_id` y `restaurant_id` exactamente iguales a los
enviados. Las confirmaciones de duplicado también son exitosas. No basta con
recibir HTTP 200 si la confirmación está vacía, incompleta o es incompatible.

En éxito, se actualizan conjuntamente `dispatch_status: "sent"`,
`dispatched_at` y `last_dispatch_error: null`. Ante un fallo esperado de
transporte, timeout, HTTP o confirmación, se guardan `dispatch_status: "error"`,
`dispatched_at: null` y un mensaje operacional breve. No se guardan cuerpos de
respuesta, URLs, datos del cliente ni mensajes originales de excepciones.
Los errores inesperados y los fallos de base de datos al guardar el resultado
no se convierten en errores de transporte ni se ocultan.

El cliente del POST espera mientras se despacha; los timeouts son por operación,
no un límite global. No hay jobs ni reintentos automáticos. Tampoco se coordinan
llamadas de despacho simultáneas para una orden.
La tienda puede haber aceptado aunque el emisor pierda la confirmación o falle
al guardar el resultado. Un envío posterior con el mismo identificador puede
confirmarse como duplicado, mientras el receptor conserve su memoria; reiniciar
el receptor elimina esa protección.

## Reintento manual del despacho

`POST /api/v1/orders/:id/retry_dispatch` reenvía una orden existente que esté en
`pending` o `error`. No requiere payload; cualquier body se ignora, incluido un
ID o destino alternativo. Solo se usan el identificador de la ruta y los datos
persistidos. No crea otra orden ni ítems, no recalcula el total y no toma precios
actuales del catálogo.

Con Rails y el receptor local iniciados, reintentar una orden existente
(el identificador 9001 es ilustrativo):

```sh
curl -i -X POST http://localhost:3000/api/v1/orders/9001/retry_dispatch \
  -H 'Accept: application/json'
```

Un intento completado responde HTTP 200, incluso si el despacho vuelve a fallar.
Ejemplo de éxito:

```json
{
  "data": {
    "id": 9001,
    "restaurant_id": 1,
    "order_type": "pickup",
    "total_amount": 17980,
    "client_total_amount": null,
    "dispatch_status": "sent",
    "created_at": "2026-10-22T12:00:00.000Z",
    "dispatched_at": "2026-10-22T12:05:00.000Z",
    "last_dispatch_error": null
  }
}
```

Ante un nuevo fallo esperado, la respuesta sigue siendo HTTP 200 con los mismos
campos, `dispatch_status: "error"`, `dispatched_at: null` y el mensaje actualizado
en `last_dispatch_error`, por ejemplo `"Store returned HTTP 503"`. El pedido y
sus ítems se conservan. Un HTTP 200 de este endpoint significa que terminó el
intento; el estado de `data` indica su resultado.

Si no existe la orden, responde HTTP 404 sin intentar el envío:

```json
{"errors":[{"field":"id","code":"not_found","message":"Order not found"}]}
```

Si ya está `sent` al comprobar su estado, responde HTTP 409 sin enviar ni modificar:

```json
{"errors":[{"field":"dispatch_status","code":"already_sent","message":"Order has already been sent"}]}
```

Se reenvía el mismo `order_id` porque la tienda pudo haber aceptado el primer
despacho aunque Rails perdiera la confirmación. Una confirmación con
`duplicate: true` permite recuperar `sent`, registrar la fecha y limpiar el error.
El receptor solo recuerda IDs en memoria; reiniciarlo elimina esa protección.

El endpoint reutiliza `Orders::Dispatch`, mantiene sus timeouts y propaga fallos
inesperados. No envía HTTP dentro de una transacción ni mantiene bloqueos de
base de datos durante el envío. La comprobación previa del estado **no garantiza
exclusión entre solicitudes simultáneas**: pueden salir varios POST para una
misma orden. No hay coordinación adicional ni una garantía de entrega exactamente
una vez entre procesos o reinicios del receptor.
