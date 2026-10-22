# Alcance de la prueba técnica de Niu Foods

## Objetivo

API Rails que reciba, valide y persista órdenes en PostgreSQL, calcule sus
montos y las envíe por HTTP a una tienda simulada.

El desarrollo se organiza en incrementos pequeños, con revisión
de cambios y verificación de cada resultado antes de continuar.

## Entorno informado

Pendiente de verificar localmente:

- Ruby 3.4.11.
- Bundler 4.0.22.
- Rails 8.1.4.
- PostgreSQL 18.6.

Entorno de trabajo informado: Ubuntu/WSL, con OpenCode y VS Code.

## Modelo acordado

El modelo representa el diseño previsto, todavía no implementado.

Todas las tablas tienen `id` de tipo `bigint`, y `created_at` y `updated_at`
de tipo `datetime`. Las referencias corresponden a columnas `bigint` con
claves foráneas.

### restaurants

| Campo | Tipo | Restricciones |
| --- | --- | --- |
| name | string | |
| code | string | Único |
| dispatch_url | string | |

### products

| Campo | Tipo | Restricciones |
| --- | --- | --- |
| name | string | |
| sku | string | Único |
| price | integer | Monto entero no negativo en CLP |

### orders

| Campo | Tipo | Restricciones |
| --- | --- | --- |
| restaurant_id | referencia | A Restaurant |
| order_type | integer | Obligatorio; enum: `pickup: 0`, `delivery: 1`; sin valor por defecto |
| customer_name | string | Obligatorio |
| customer_phone | string | Obligatorio |
| delivery_address | string | Permite nulo para `pickup`; obligatoria para `delivery` |
| client_total_amount | integer | Opcional; si se informa, monto entero no negativo en CLP |
| total_amount | integer | Monto entero no negativo en CLP |
| dispatch_status | integer | Obligatorio; enum: `pending: 0`, `sent: 1`, `error: 2`; por defecto `pending` |
| last_dispatch_error | text | Permite nulo |
| dispatched_at | datetime | Permite nulo; fecha de confirmación de recepción en tienda |

### order_items

| Campo | Tipo | Restricciones |
| --- | --- | --- |
| order_id | referencia | A Order |
| product_id | referencia | A Product |
| quantity | integer | Entero mayor que cero |
| unit_price | integer | Monto entero no negativo en CLP |

Unicidad compuesta de `order_id` y `product_id`.

### Relaciones

- Restaurant tiene muchas Orders.
- Order pertenece a Restaurant y tiene muchos OrderItems.
- Product tiene muchos OrderItems.
- OrderItem pertenece a Order y Product.

## Reglas de negocio

- Restaurante y productos deben existir.
- Nombre y teléfono del cliente obligatorios.
- Dirección obligatoria para `delivery`.
- Al menos un ítem y cantidades enteras positivas.
- Rechazar productos repetidos dentro de una orden.
- Tomar precios del catálogo y conservarlos en `unit_price`.
- Calcular siempre `total_amount` desde los precios del catálogo, como suma de `quantity * unit_price`.
- `client_total_amount` es opcional y, si se informa, debe ser un entero no negativo en CLP; no sustituye nuestro cálculo.
- Si no se informa `client_total_amount`, procesar la orden con el total calculado; si se informa, procesarla solo si coincide exactamente en pesos enteros CLP.
- Si los totales difieren, responder HTTP 422 sin persistir la orden ni sus ítems y sin intentar el despacho.
- Conservar `client_total_amount` en las órdenes aceptadas cuando fue informado. No almacenar intentos rechazados.
- Guardar orden e ítems en una transacción.
- Despachar después de confirmar esa transacción.
- Un fallo de envío conserva la orden y registra estado `error`.

## Requisitos y decisiones de diseño

- El cálculo y la persistencia del total en el servidor son requisitos de la prueba.
- Recibir, comparar y conservar `client_total_amount` en órdenes aceptadas es una decisión de diseño de la solución; el payload de referencia no incluye ese campo. La política se detalla en «Política de comparación de totales».
- Rechazar productos repetidos, exigir nombre y teléfono y ofrecer reintento manual son decisiones de esta solución, no exigencias explícitas de Niu Foods.

## API

- `POST /api/v1/orders`.
- Solo se aceptan los strings `"pickup"` o `"delivery"` como `order_type`.
- El almacenamiento interno usa el enum `integer` acordado.
- Los enums se devuelven con sus nombres.
- Respuestas exitosas bajo `data`; errores bajo `errors`.
- Cada error contiene `field`, `code` y `message`.
- HTTP 201 si se creó la orden, incluso si falló el despacho.
- HTTP 422 por validación; HTTP 400 para JSON mal formado.
- `client_total_amount` es opcional; si se informa, debe ser un entero no negativo. Si se omite o coincide exactamente con `total_amount` en pesos enteros CLP, la orden se procesa conforme a las demás validaciones.
- Si `client_total_amount` difiere de `total_amount`, responder HTTP 422 sin persistir la orden ni sus ítems y sin intentar el despacho. El error bajo `errors` utiliza `field: "client_total_amount"`, `code: "total_mismatch"` y un `message` que indica el monto declarado y el calculado, ambos en CLP.
- Referencias a restaurante o productos inexistentes en el POST invalidan la orden y generan HTTP 422.
- Un fallo de validación no guarda registros parciales ni despacha.
- Los atributos enviados por el cliente no pueden establecer valores internos como `unit_price`, `total_amount` ni `dispatch_status`.
- Queda pendiente decidir si los atributos no permitidos se ignoran o se rechazan.

### Consultas de órdenes

- `GET /api/v1/orders` responde HTTP 200 con `{ "data": [...] }`; si no hay órdenes, devuelve `{ "data": [] }`.
- El listado incluye `id`, `restaurant_id`, `restaurant` con `id`, `name` y `code`, `total_amount`, `order_type`, `created_at` y `dispatch_status`.
- Se ordena por `created_at` descendente y, en caso de empate, por `id` descendente. No hay filtros ni paginación en este incremento.
- El listado no incluye cliente, dirección, ítems ni otros datos privados del detalle.
- `GET /api/v1/orders/:id` responde HTTP 200 con `{ "data": {...} }`.
- El detalle incluye los campos del listado más `client_total_amount`, `customer` con `name` y `phone`, `delivery_address`, `dispatched_at`, `last_dispatch_error` e `items`.
- Cada ítem contiene `id`, `product_id`, `product_name`, `sku`, `quantity`, `unit_price` y `subtotal`; se ordenan por `id` ascendente.
- `product_name` y `sku` proceden del catálogo actual. `unit_price` es el precio histórico persistido al crear la orden; `subtotal` se obtiene como `quantity * unit_price` sin modificar ni recalcular `total_amount`.
- Los importes son números enteros CLP, los enums se devuelven por nombre y las fechas son strings ISO 8601 con milisegundos y zona horaria. La presentación local corresponde a Angular. Los campos opcionales sin valor se devuelven como `null`.
- Una orden inexistente responde HTTP 404 con `errors: [{ field: "id", code: "not_found", message: "Order not found" }]`.
- Ninguna consulta expone `dispatch_url`, modifica datos ni inicia despachos. Los contratos de creación y reintento se mantienen sin cambios.

### Reintento manual del despacho

- `POST /api/v1/orders/:id/retry_dispatch` no requiere payload; cualquier body se ignora y el identificador se toma exclusivamente de la ruta.
- Solo las órdenes `pending` o `error` son elegibles. Se reutiliza `Orders::Dispatch` con la orden persistida, sin crear órdenes o ítems ni cambiar datos del pedido.
- HTTP 200 cuando termina un intento, tanto si el estado final es `sent` como `error`.
- La respuesta conserva `data` y contiene `id`, `restaurant_id`, `order_type`, `total_amount`, `client_total_amount`, `dispatch_status`, `created_at`, `dispatched_at` y `last_dispatch_error`.
- HTTP 404 si no existe la orden: `field: "id"`, `code: "not_found"`, `message: "Order not found"`.
- HTTP 409 si ya está `sent` al comprobar su estado: `field: "dispatch_status"`, `code: "already_sent"`, `message: "Order has already been sent"`. No se envía HTTP ni se modifica la orden.
- Los errores 404 y 409 mantienen la envoltura `errors` con `field`, `code` y `message`. Los fallos inesperados se propagan.

El reintento conserva el mismo `order_id` y los montos y precios históricos.
Esto permite confirmar una recepción previa cuya respuesta se perdió:
`duplicate: true` también produce `sent`. No hay HTTP dentro de transacciones
ni bloqueos de base de datos que abarquen la llamada de red.

Comprobar el estado no garantiza exclusión entre solicitudes simultáneas:
dos solicitudes pueden superar la comprobación y enviar HTTP. La detección de
duplicados del receptor evita una segunda aceptación mientras conserve su
memoria, pero reiniciarlo elimina esa protección.

### Simulación de órdenes

El cliente independiente `script/simulate_orders.rb` usa Net::HTTP y JSON, sin
cargar Rails ni consultar PostgreSQL. Envía únicamente `POST /api/v1/orders`;
no consulta ni ejecuta reintentos de despacho.

- `API_BASE_URL` vale `http://localhost:3000` por defecto. Debe ser una URL HTTP/HTTPS con host y puerto válido, sin credenciales, query ni fragmento; admite un prefijo de ruta antes de `/api/v1/orders`.
- `ORDER_COUNT` es un entero positivo y vale 6 por defecto: cubre los tres restaurantes del catálogo y ambos tipos. Cantidades mayores repiten esos cruces.
- `RANDOM_SEED` es un entero opcional. La semilla usada se imprime y permite reproducir los payloads, no los IDs ni los resultados del servidor.
- Se usan IDs y precios del dataset de referencia, ítems distintos con cantidades variables y solo clientes y direcciones ficticios. Se alterna `client_total_amount` omitido y coincidente.
- Los precios locales solo construyen el monto declarado de la simulación; la API calcula el total real. Los casos coincidentes y las referencias válidas presuponen los seeds sin cambios.
- Después se ejecutan cantidad cero (`items[0].quantity`/`greater_than`), producto inexistente (`items[0].product_id`/`blank`), producto repetido (`items`/`invalid`, mensaje `must not contain duplicate products`), delivery sin dirección (`delivery_address`/`blank`) y monto diferente (`client_total_amount`/`total_mismatch`).
- Un 422 solo comprueba un escenario inválido si la respuesta tiene errores con `field`, `code` y `message` válidos y contiene el error concreto esperado. Una aceptación o rechazo por otro motivo es inesperado.
- Un 201 válido con `sent` o `error` cuenta como creación, no como rechazo. Los fallos de despacho se cuentan por separado y permanecen visibles. Una respuesta 201 con `pending` se informa como inesperada.
- Se envía un POST por escenario, sin seguir redirecciones ni repetirlo ante un resultado ambiguo. Los timeouts son 2 s de conexión, 20 s de lectura y 5 s de escritura, con `max_retries: 0` y verificación de certificados HTTPS.
- Salida 0 si todos los escenarios cumplen su expectativa de creación o rechazo; salida 1 ante transporte, JSON, estructura o resultados inesperados; salida 2 ante configuración inválida, antes de enviar. Los errores de programación se propagan.

El resumen distingue creaciones confirmadas, estados de despacho, rechazos
esperados y fallos inesperados. Un timeout o una respuesta incomprensible puede
ocultar una creación ya realizada: no se repite el POST automáticamente.
Ejecutarlo contra una API real crea órdenes; repetirlo, incluso con la misma
semilla, crea órdenes nuevas. No borra registros ni reinicia bases.

## Integración

- Despacho síncrono a `dispatch_url`.
- Tienda simulada Ruby con éxito, error y demora.
- Un despacho confirmado cambia `dispatch_status` a `sent`, registra `dispatched_at` y limpia `last_dispatch_error`.
- Un fallo o timeout cambia `dispatch_status` a `error` y conserva la orden.
- Reintento manual sobre la misma orden, utilizando el mismo identificador de orden.
- Receptor reconoce `order_id` para evitar duplicados.
- Órdenes `pending` o `error` pueden reintentarse; órdenes `sent` no.
- La confirmación de recepción no implica preparación ni entrega.
- Timeouts del emisor: conexión 2 s, lectura 5 s y escritura 5 s; sin reintentos automáticos ni seguimiento de redirecciones.

El flujo del POST es guardar orden e ítems, confirmar la transacción, ejecutar
`Orders::Dispatch`, registrar conjuntamente el resultado y responder HTTP 201
con el estado persistido `sent` o `error`. `Orders::Create` conserva únicamente
la responsabilidad de crear y persistir. Una orden rechazada no se despacha.

`Orders::Dispatch` exige una orden persistida y realiza el envío fuera de
transacciones de base de datos y callbacks. Recarga los datos persistidos y no
reenvía una orden que ya esté en `sent`. El emisor usa HTTP o HTTPS con
verificación de certificados y no recalcula precios históricos.

Un resultado HTTP 2xx solo confirma el despacho si el cuerpo es JSON válido,
`data.accepted` es el booleano `true` y `order_id` y `restaurant_id` son enteros
exactamente iguales a los enviados. `duplicate: true` también confirma éxito.
Un cuerpo vacío, JSON inválido o una confirmación incompleta o incompatible
se registra como error, igual que un fallo de red, protocolo o timeout.

Los mensajes de `last_dispatch_error` contienen solo el estado HTTP, el tipo
de fallo de transporte o una descripción fija de confirmación inválida; no
guardan cuerpos, URLs, datos de cliente ni mensajes originales de excepciones.
Los errores inesperados y los fallos de base de datos al registrar el resultado
se propagan, sin reclasificarlos como errores de transporte.

El envío es síncrono y mantiene ocupada la solicitud HTTP. Los timeouts son por
operación, no un límite global. No hay reintentos automáticos ni exclusión de llamadas de
despacho concurrentes. Una tienda puede aceptar aunque se pierda la respuesta o
falle el registro local del resultado. Un envío posterior del mismo `order_id`
al mismo restaurante puede recuperar esa situación gracias a la confirmación
de duplicado mediante el endpoint de reintento manual; la memoria del receptor
se pierde al reiniciar.

### Contrato del receptor simulado

El receptor independiente recibe `POST` con `Content-Type: application/json`
en `/restaurants/PROV/orders`, `/restaurants/LCON/orders` y
`/restaurants/NUNO/orders`. Los destinos corresponden respectivamente a
`restaurant_id` 1, 2 y 3 del catálogo de referencia; no consulta la base de Rails.

El emisor envía un objeto JSON directamente en la raíz:

```json
{
  "order_id": 9001,
  "restaurant_id": 1,
  "order_type": "pickup",
  "customer": { "name": "Test Customer", "phone": "+56000000000" },
  "delivery_address": null,
  "total_amount": 17980,
  "items": [ { "product_id": 1, "quantity": 2, "unit_price": 8990 } ]
}
```

- `order_id`, `restaurant_id` y cada `product_id` son enteros positivos.
- `restaurant_id` debe coincidir con el destino de la ruta.
- `order_type` es `"pickup"` o `"delivery"`.
- `customer` contiene `name` y `phone` como strings no vacíos.
- `delivery_address` puede omitirse o ser `null` para pickup; para delivery es un string no vacío.
- `total_amount` y cada `unit_price` son enteros no negativos en CLP.
- `items` es un array no vacío de objetos con `product_id`, `quantity` y `unit_price`; `quantity` es un entero positivo.
- Los precios unitarios y el total son los valores históricos persistidos por Rails. El receptor valida su tipo, pero no los recalcula ni verifica productos contra un catálogo.
- `client_total_amount` y los campos de estado de despacho no forman parte del payload requerido. Los atributos adicionales no intervienen en la aceptación.

La recepción y los reenvíos ya aceptados responden HTTP 200 con:

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

Un duplicado conserva esa confirmación y devuelve `duplicate: true`. El
emisor comprueba un estado HTTP 2xx, `accepted: true` y que ambos identificadores
coincidan con el despacho. La confirmación no implica preparación ni entrega.

Los errores usan `errors` con `field`, `code` y `message`: HTTP 400 para JSON
malformado, 404 para ruta desconocida, 405 para método no permitido (con
`Allow: POST`), 415 para tipo de contenido distinto de JSON, 422 para payload o
identificadores inválidos y 503 para el fallo simulado.

Los modos son `success`, `error` y `delay`. El modo error no acepta la orden.
En demora se acepta después de esperar; un timeout o cierre del emisor no
cancela esa aceptación posterior. Un reenvío ya aceptado se confirma sin otra
demora. La memoria de duplicados se limita a pares restaurante/orden en un solo
proceso, con acceso sincronizado; reiniciarlo borra esa memoria. No se conserva
el payload ni se añade persistencia.

## Interfaz

- Backend primero.
- Preferencia Angular con soporte + Bootstrap, sin signals.
- Decisión final al completar el flujo backend.
- Alternativa Rails ERB si falta tiempo.
- Conservar soporte de vistas en Rails.
- No construir ambas interfaces.

## Entregables

- Diagramas.
- Seeds del dataset de referencia.
- API.
- Receptor.
- Script Ruby generador.
- Dashboard.
- Pruebas relevantes.
- README reproducible.
- Historial de commits.

Los commits se realizarán después de revisar los cambios y sus
verificaciones. Las reglas operativas del agente se mantienen
en AGENTS.md.

## Fuera de alcance

- Autenticación.
- Pagos.
- Seguimiento de repartidores.
- Administración del catálogo.
- Integraciones reales con plataformas de venta.

## Política de comparación de totales

Esta política es una decisión de diseño de la solución, no una exigencia
explícita de Niu Foods.

- `total_amount` siempre se calcula desde los precios del catálogo.
- `client_total_amount` es opcional y debe ser un entero no negativo si se informa.
- Si no se informa, la orden se procesa con el total calculado.
- Si se informa y coincide exactamente con `total_amount`, la orden se procesa.
- La comparación es exacta en pesos enteros CLP.
- Si difiere, se responde HTTP 422 sin persistir la orden ni sus ítems y sin intentar el despacho.
- El error utiliza `field: "client_total_amount"` y `code: "total_mismatch"`. El mensaje indica ambos montos, identificando el declarado y el calculado en CLP.
- `client_total_amount` se conserva en las órdenes aceptadas cuando fue informado. No se almacenan intentos rechazados.

La coincidencia de totales no exime del cumplimiento de las demás validaciones.

Justificación: evitar procesar una compra por un importe distinto al declarado
por el canal, manteniendo el catálogo como fuente del cálculo. El alcance
actual no contempla descuentos ni cargos adicionales.
