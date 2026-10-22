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

## Consultas de órdenes

Las consultas son de solo lectura y no necesitan que el receptor esté iniciado.
No crean ni actualizan registros ni envían HTTP a las tiendas.

### Listado

```sh
curl -i http://localhost:3000/api/v1/orders \
  -H 'Accept: application/json'
```

Responde HTTP 200. Ejemplo ilustrativo con una orden:

```json
{
  "data": [
    {
      "id": 9001,
      "restaurant_id": 1,
      "restaurant": { "id": 1, "name": "Niu Foods Providencia", "code": "PROV" },
      "total_amount": 17980,
      "order_type": "pickup",
      "created_at": "2026-10-22T12:00:00.000Z",
      "dispatch_status": "pending"
    }
  ]
}
```

Sin órdenes devuelve `{"data":[]}`. El orden es `created_at` descendente y
después `id` descendente para resolver empates. No hay filtros ni paginación:
se devuelven todas las órdenes. El listado no incluye cliente, dirección ni
ítems; tampoco expone la URL de despacho.

### Detalle

El identificador 9001 es ilustrativo; debe corresponder a una orden existente:

```sh
curl -i http://localhost:3000/api/v1/orders/9001 \
  -H 'Accept: application/json'
```

Responde HTTP 200 con los campos del listado y los datos adicionales del pedido:

```json
{
  "data": {
    "id": 9001,
    "restaurant_id": 1,
    "restaurant": { "id": 1, "name": "Niu Foods Providencia", "code": "PROV" },
    "total_amount": 17980,
    "order_type": "pickup",
    "created_at": "2026-10-22T12:00:00.000Z",
    "dispatch_status": "pending",
    "client_total_amount": null,
    "customer": { "name": "Test Customer", "phone": "+56000000000" },
    "delivery_address": null,
    "dispatched_at": null,
    "last_dispatch_error": null,
    "items": [
      {
        "id": 7001,
        "product_id": 1,
        "product_name": "Niu Roll Salmón",
        "sku": "SKU-001",
        "quantity": 2,
        "unit_price": 8990,
        "subtotal": 17980
      }
    ]
  }
}
```

Los ítems se ordenan por ID ascendente. `product_name` y `sku` reflejan el
catálogo actual; pueden cambiar si se actualiza el producto. En cambio,
`unit_price` conserva el precio al momento de la compra y `subtotal` es
`quantity * unit_price` histórico. La consulta devuelve `total_amount` guardado,
sin recalcularlo ni sustituir precios por los actuales del catálogo.

Todos los importes son números enteros CLP. Los enums son strings (`pickup`,
`delivery`, `pending`, `sent`, `error`), las fechas usan ISO 8601 con milisegundos
y zona horaria, y los valores opcionales ausentes son `null`. Angular realizará
la presentación local de fechas e importes.

Para una orden inexistente responde HTTP 404 con el mismo contrato que el reintento:

```json
{"errors":[{"field":"id","code":"not_found","message":"Order not found"}]}
```

El listado precarga solo restaurantes; no consulta ítems ni productos. El detalle
precarga restaurante, ítems y productos para evitar consultas adicionales por
cada registro. Estas representaciones no cambian las respuestas de creación ni
de reintento.

## Simulador de órdenes

`script/simulate_orders.rb` es un cliente HTTP independiente que usa Net::HTTP y
JSON. No carga Rails ni accede directamente a PostgreSQL. Requiere Ruby y una
API con las migraciones aplicadas y los seeds de referencia cargados según la
sección «Catálogo de referencia».

**Ejecutarlo contra una API real crea órdenes. Repetirlo crea órdenes nuevas,
incluso con la misma semilla.** No elimina lo generado ni reinicia bases. Los
ejemplos siguientes son instrucciones de ejecución manual, no una verificación
automática sobre desarrollo.

### Tres terminales

En la primera terminal, iniciar Rails desde la raíz del proyecto:

```sh
~/.local/bin/mise exec -- bin/rails server
```

En la segunda, iniciar el receptor local; detenerlo con `Ctrl+C` al terminar:

```sh
~/.local/bin/mise exec -- bundle exec ruby script/store_receiver.rb
```

En la tercera, ejecutar el simulador:

```sh
~/.local/bin/mise exec -- ruby script/simulate_orders.rb
```

O configurar la cantidad y una semilla reproducible:

```sh
API_BASE_URL=http://localhost:3000 ORDER_COUNT=12 RANDOM_SEED=42 \
  ~/.local/bin/mise exec -- ruby script/simulate_orders.rb
```

El simulador termina después de sus escenarios. Rails y el receptor se detienen
con `Ctrl+C` en sus respectivas terminales. No es necesario borrar órdenes.

### Configuración y escenarios

| Variable | Predeterminado | Validación |
| --- | --- | --- |
| `API_BASE_URL` | `http://localhost:3000` | HTTP/HTTPS con host y puerto entre 1 y 65535, sin credenciales, query ni fragmento. Un prefijo como `/prefix` produce `/prefix/api/v1/orders`. |
| `ORDER_COUNT` | `6` | Entero positivo: número de escenarios válidos. |
| `RANDOM_SEED` | Aleatoria, impresa en consola | Entero opcional para reproducir payloads. |

Con al menos seis órdenes se cubren PROV, LCON y NUNO con pickup y delivery.
Cada orden tiene entre uno y tres productos distintos, cantidades entre uno y
cuatro y datos de cliente ficticios; delivery incluye una dirección ficticia.
Se alternan el monto declarado omitido y el coincidente.

Los precios locales se usan exclusivamente para construir `client_total_amount`.
La API sigue calculando el total con su catálogo. Los escenarios coincidentes
presuponen los IDs y precios originales de los seeds; cambiar el catálogo puede
producir resultados inesperados, que el script informa sin modificarlo.

Después se ejecutan cinco casos inválidos, de modo que el valor predeterminado
produce once POST en total:

| Escenario | Error esperado |
| --- | --- |
| `quantity_zero` | `items[0].quantity` / `greater_than` |
| `product_not_found` | `items[0].product_id` / `blank` |
| `duplicate_product` | `items` / `invalid`, con mensaje `must not contain duplicate products` |
| `delivery_without_address` | `delivery_address` / `blank` |
| `total_mismatch` | `client_total_amount` / `total_mismatch` |

No basta un 422 cualquiera: debe contener el error esperado. Para productos
repetidos se exige también el mensaje porque `invalid` es un código genérico.
Si un caso inválido se acepta o falla por otra causa, se registra como inesperado.

### Resultados y códigos

Por cada POST se imprimen escenario, restaurante, tipo, HTTP, ID, total y estado
de despacho cuando están disponibles. Los errores se muestran como
`field`/`code`/`message`, sin imprimir el payload, el cliente ni la dirección.
Ejemplo ilustrativo, no obtenido ejecutando el simulador contra desarrollo:

```text
scenario=valid_1 restaurant=1 order_type=pickup http=201 id=9001 total=8990 dispatch_status=sent result=created
scenario=valid_2 restaurant=1 order_type=delivery http=201 id=9002 total=17980 dispatch_status=error result=created_dispatch_error
Summary created=6 sent=5 error=1 pending=0 expected_rejections=5 unexpected_failures=0
```

HTTP 201 con estado `error` significa **orden creada con fallo de despacho**;
no es un rechazo de validación. Se cuenta entre las creaciones y separadamente
en `error`. Un 422 esperado no crea una orden y aumenta `expected_rejections`.
Las respuestas 201 válidas que acepten un escenario inválido también se cuentan
como creaciones, pero aumentan `unexpected_failures`.

| Código de salida | Significado |
| --- | --- |
| `0` | Todos los escenarios cumplen la expectativa de creación o rechazo. Puede haber creaciones con despacho `error`; revisar el resumen. |
| `1` | Fallos inesperados de transporte, respuesta JSON, estructura, HTTP o resultado del escenario. |
| `2` | Configuración inválida: no se inicia ningún envío. |

El resumen cuenta creaciones cuya respuesta tiene la estructura válida del
contrato. Si hay timeout o la respuesta es incomprensible, la API puede haber
creado la orden aunque no pueda confirmarse localmente. No se repite ese POST:
se continúa con el siguiente escenario, sin seguir redirecciones ni ejecutar
reintentos manuales de despacho. Los errores de programación se propagan.

Se usan conexión directa sin proxy de entorno, verificación TLS para HTTPS y
timeouts de conexión de 2 s, lectura de 20 s y escritura de 5 s, con cero
reintentos automáticos. La lectura permite esperar el despacho síncrono de la
API, pero no constituye un timeout global.

Las pruebas del simulador usan transporte sustituido, sin Rails ni servidores:

```sh
~/.local/bin/mise exec -- bundle exec ruby -Itest test/lib/order_simulator_test.rb
```
