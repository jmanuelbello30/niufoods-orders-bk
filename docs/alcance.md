# Alcance de la prueba técnica de Niu Foods

## Objetivo

API Rails que reciba, valide y persista órdenes en PostgreSQL, calcule sus
montos y las envíe por HTTP a una tienda simulada.

El desarrollo se organiza en incrementos pequeños, con revisión
de cambios y verificación de cada resultado antes de continuar.

## Entorno informado

- Ruby 3.4.11, fijado en `mise.toml` y `.ruby-version`.
- Bundler 4.0.22, registrado en `Gemfile.lock`.
- Rails 8.1.4, resuelto en `Gemfile.lock`.
- PostgreSQL 18.6 en el entorno local, comprobado con `SHOW server_version`,
  y cliente `psql` 18.6. El proyecto no fija la versión del servidor ni establece
  una versión mínima comprobada.

Entorno de trabajo informado: Ubuntu/WSL, con OpenCode y VS Code.

### Configuración local

`config/database.yml` configura `niufoods_orders_development` para development
y `niufoods_orders_test` para test. Por defecto no especifica usuario,
contraseña ni host: usa el usuario del sistema operativo y el socket local de
PostgreSQL. `DATABASE_URL` puede sobrescribir el destino y otros parámetros de
esa configuración; no basta con elegir `RAILS_ENV` para garantizar la base usada.

Antes de migraciones, seeds o aprovisionamiento, revisar la conexión y confirmar
que apunta a la base de este proyecto. Para pruebas, comprobar también
`DATABASE_URL` y usar exclusivamente `niufoods_orders_test`, nunca desarrollo,
producción ni bases ajenas. No ejecutar operaciones destructivas sobre bases
existentes o ajenas al proyecto.

Las variables se proporcionan mediante el entorno de la terminal. El proyecto
no usa dotenv ni incluye `.env.example`. Si Ruby no está en `PATH`, puede
anteponerse `~/.local/bin/mise exec --` a los comandos Ruby, Bundler o Rails.

## Modelo acordado

El modelo de órdenes descrito a continuación está implementado en los modelos,
migraciones y `db/schema.rb`. La autenticación añade `users` y `api_sessions`;
su comportamiento se describe en «Autenticación».

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

## Catálogo de referencia

`db/seeds.rb` define estos 10 productos, con precios enteros en CLP:

| ID | Producto | SKU | Precio CLP |
| --- | --- | --- | --- |
| 1 | Niu Roll Salmón | SKU-001 | 8990 |
| 2 | California Ebi | SKU-002 | 7490 |
| 3 | Avocado Roll | SKU-003 | 6990 |
| 4 | Nigiri Salmón x2 | SKU-004 | 3990 |
| 5 | Gyozas de Pollo x5 | SKU-005 | 4490 |
| 6 | Edamame | SKU-006 | 3290 |
| 7 | Bowl Salmón Teriyaki | SKU-007 | 9990 |
| 8 | Bowl Pollo Teriyaki | SKU-008 | 8990 |
| 9 | Bebida 350 ml | SKU-009 | 1990 |
| 10 | Agua Mineral 500 ml | SKU-010 | 1590 |

Los tres restaurantes y sus destinos locales de despacho son:

| ID | Restaurante | Código | `dispatch_url` |
| --- | --- | --- | --- |
| 1 | Niu Foods Providencia | PROV | `http://localhost:4567/restaurants/PROV/orders` |
| 2 | Niu Foods Las Condes | LCON | `http://localhost:4567/restaurants/LCON/orders` |
| 3 | Niu Foods Ñuñoa | NUNO | `http://localhost:4567/restaurants/NUNO/orders` |

Con las migraciones aplicadas y la conexión de desarrollo verificada, la carga
se realiza con `RAILS_ENV=development bin/rails db:seed`. Usa las validaciones
de los modelos y una única transacción para evitar cargas parciales. No envía
solicitudes HTTP ni provisiona usuarios.

La carga es idempotente: busca coincidencias por ID o SKU para productos y por
ID o código para restaurantes. Si todos los atributos de referencia coinciden,
conserva el registro sin duplicarlo ni cambiar sus timestamps. Si un ID, SKU o
código está ocupado por otro registro, o difiere algún atributo de referencia,
falla con `Seed conflict` y revierte la carga. No borra ni sobrescribe registros;
conserva los registros ajenos sin conflictos. Al terminar ajusta las secuencias
PostgreSQL al máximo ID de cada tabla del catálogo para evitar colisiones en
las siguientes inserciones automáticas.

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
- La respuesta HTTP 201 incluye `id`, `restaurant_id`, `order_type`, `total_amount`, `dispatch_status` y `created_at`; no incluye `client_total_amount`, que se conserva como entrada opcional y dato persistido.
- HTTP 422 por validación; HTTP 400 para JSON mal formado.
- HTTP 422 con `code: "invalid_structure"` para JSON válido con estructura incorrecta, por ejemplo una raíz que no sea objeto o un ítem que no sea objeto. Los errores indican el campo o índice afectado.
- JSON malformado o cuerpo vacío en creación responde HTTP 400 con `field: "base"`, `code: "invalid_json"` y `message: "Malformed JSON body"`. No se exponen detalles internos de la excepción.
- `client_total_amount` es opcional; si se informa, debe ser un entero no negativo. Si se omite o coincide exactamente con `total_amount` en pesos enteros CLP, la orden se procesa conforme a las demás validaciones.
- Si `client_total_amount` difiere de `total_amount`, responder HTTP 422 sin persistir la orden ni sus ítems y sin intentar el despacho. El error bajo `errors` utiliza `field: "client_total_amount"`, `code: "total_mismatch"` y un `message` que indica el monto declarado y el calculado, ambos en CLP.
- Referencias a restaurante o productos inexistentes en el POST invalidan la orden y generan HTTP 422.
- Un fallo de validación no guarda registros parciales ni despacha.
- Los atributos enviados por el cliente no pueden establecer valores internos como `unit_price`, `total_amount` ni `dispatch_status`.
- Queda pendiente decidir si los atributos no permitidos se ignoran o se rechazan.

### Autenticación

La autenticación está implementada en el backend. Todos los endpoints de
órdenes (creación, listado, detalle y reintento), `me` y `logout` requieren una
sesión válida. El login y `/up` son públicos. El acceso de los usuarios
autenticados es compartido, sin roles ni restricciones por restaurante.

- `POST /api/v1/auth/login` recibe `email` y `password` en el cuerpo JSON directamente en la raíz, no en query. Responde HTTP 200 con `data.access_token`, `data.token_type: "Bearer"`, `data.expires_at` en ISO 8601 con milisegundos y zona horaria (`iso8601(3)`) y `data.user` con solo `id` y `email`.
- `GET /api/v1/auth/me` responde HTTP 200 con `data` que contiene solo `id` y `email` del usuario autenticado.
- `DELETE /api/v1/auth/logout` revoca inmediatamente solo la sesión presentada y responde HTTP 204 sin cuerpo; las demás sesiones siguen siendo válidas.
- Cada login crea una sesión independiente, con expiración absoluta de 8 horas, sin extensión por uso. Solo se persiste el digest SHA-256 del token, no su valor original.
- El token se acepta exclusivamente en `Authorization: Bearer <token>`, nunca en query, cuerpo ni cookies. Fuera del entorno local, HTTPS es obligatorio para proteger credenciales y tokens.
- Las respuestas de autenticación y órdenes incluyen `Cache-Control: no-store`.

Los errores de autenticación usan `errors`, con `field: "base"` en todos los casos:

| HTTP | `code` | `message` | Condición |
| --- | --- | --- | --- |
| 401 | `invalid_credentials` | `Invalid email or password` | Credenciales inválidas en login. |
| 401 | `unauthenticated` | `Valid Bearer token required` | Token ausente, inválido, expirado o revocado; incluye `WWW-Authenticate: Bearer`. |
| 429 | `rate_limit_exceeded` | `Too many login attempts` | Se supera el límite de 10 intentos de login por minuto e IP; cuentan también los exitosos. |
| 400 | `invalid_json` | `Malformed JSON body` | Cuerpo JSON malformado en login. |

El límite usa el mecanismo nativo de Rails y el almacén de caché actual:
`MemoryStore` por proceso en desarrollo y producción. No es un límite
coordinado entre procesos y se pierde al reiniciar. En test se configura
`NullStore`; las pruebas del límite sustituyen el almacén por memoria. No se
agrega infraestructura nueva.

El usuario de demostración se provisiona explícitamente con
`bin/rails demo_user:provision`, indicando `DEMO_USER_EMAIL` y
`DEMO_USER_PASSWORD`. Ambas variables son obligatorias y no tienen valores
predeterminados; la contraseña requiere al menos 12 caracteres. El correo se
normaliza quitando espacios extremos y pasando a minúsculas. Si el usuario
ya existe, la tarea falla sin sobrescribir sus credenciales. No se crea desde
los seeds. Ejemplo ficticio para desarrollo, tras verificar la conexión:

```sh
RAILS_ENV=development DEMO_USER_EMAIL=demo@example.test \
  DEMO_USER_PASSWORD='Fictional-password-123' bin/rails demo_user:provision
```

Angular ya integra el login real y el envío del encabezado Bearer; véase
«Interfaz». Swagger está disponible localmente según la sección siguiente.

### Swagger

Disponible solo en development y test, con Rails iniciado:

- UI local: `http://localhost:3000/api-docs`.
- Archivo versionado: `openapi/v1/openapi.yaml`.
- URL de la especificación: `http://localhost:3000/api-docs/v1/openapi.yaml`.
- Formato: OpenAPI 3.0.3, importable en Swagger Editor.

La especificación actual documenta exactamente `POST /api/v1/auth/login` y
`POST /api/v1/orders`. Sus bloques de respuestas
documentan solo el éxito principal: HTTP 200 para login y HTTP 201 para creación.
No constituye una descripción completa de los endpoints ni de los errores de
la API; los contratos adicionales se conservan en este documento.

Tras provisionar un usuario, ejecutar login con **Try it out / Execute**, copiar
manualmente `data.access_token` y pegar solo el token, sin `Bearer`, en
**Authorize**. El login no autoriza automáticamente otras operaciones y la UI
no persiste la autorización. Al vencer la sesión, obtener otro token y
autorizarlo manualmente. Las respuestas de login y creación incluyen
`Cache-Control: no-store`.

Los ejemplos de órdenes presuponen el catálogo de referencia. Ejecutar una
orden válida crea registros reales; HTTP 201 confirma creación, no recepción
en tienda. Para obtener `sent`, el receptor debe estar disponible y confirmar
el despacho; un fallo esperado conserva la orden con estado `error`.

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
- `API_TOKEN` es obligatorio, no vacío y sin valor predeterminado. Se obtiene por login y se exporta manualmente antes de ejecutar el simulador; se envía solo en `Authorization: Bearer <token>`. El simulador no imprime el token ni hace login automático. Fuera del entorno local debe usarse HTTPS.
- `ORDER_COUNT` es un entero positivo y vale 6 por defecto: cubre los tres restaurantes del catálogo y ambos tipos. Cantidades mayores repiten esos cruces.
- `RANDOM_SEED` es un entero opcional. La semilla usada se imprime y permite reproducir los payloads, no los IDs ni los resultados del servidor.
- Se usan IDs y precios del dataset de referencia, entre 1 y 3 productos distintos por orden, cantidades de 1 a 4 por ítem y solo clientes y direcciones ficticios. Se alterna `client_total_amount` omitido y coincidente.
- Los precios locales solo construyen el monto declarado de la simulación; la API calcula el total real. Los casos coincidentes y las referencias válidas presuponen los seeds sin cambios.
- Después se ejecutan cantidad cero (`items[0].quantity`/`greater_than`), producto inexistente (`items[0].product_id`/`blank`), producto repetido (`items`/`invalid`, mensaje `must not contain duplicate products`), delivery sin dirección (`delivery_address`/`blank`) y monto diferente (`client_total_amount`/`total_mismatch`).
- Un 422 solo comprueba un escenario inválido si la respuesta tiene errores con `field`, `code` y `message` válidos y contiene el error concreto esperado. Una aceptación o rechazo por otro motivo es inesperado.
- Un 201 válido con `sent` o `error` cuenta como creación, no como rechazo. Los fallos de despacho se cuentan por separado y permanecen visibles. Una respuesta 201 con `pending` se informa como inesperada.
- Se envía un POST por escenario, sin seguir redirecciones ni repetirlo ante un resultado ambiguo. Los timeouts son 2 s de conexión, 20 s de lectura y 5 s de escritura, con `max_retries: 0` y verificación de certificados HTTPS.
- Salida 0 si todos los escenarios cumplen su expectativa de creación o rechazo; salida 1 ante transporte, JSON, estructura o resultados inesperados; salida 2 ante configuración inválida, antes de enviar. Los errores de programación se propagan.
- Ante HTTP 401 o 403, aborta inmediatamente los escenarios restantes y termina con salida 1. Si falta `API_TOKEN` o está vacío, termina con salida 2 sin enviar solicitudes.

El resumen distingue creaciones confirmadas, estados de despacho, rechazos
esperados y fallos inesperados. Un timeout o una respuesta incomprensible puede
ocultar una creación ya realizada: no se repite el POST automáticamente.
Ejecutarlo contra una API real crea órdenes; repetirlo, incluso con la misma
semilla, crea órdenes nuevas. No borra registros ni reinicia bases.

Por cada POST se imprimen escenario, restaurante, tipo, HTTP, ID, total y estado
de despacho cuando están disponibles; los errores se muestran con
`field`/`code`/`message`, sin imprimir payload, cliente ni dirección. El resumen
usa `created`, `sent`, `error`, `pending`, `expected_rejections` y
`unexpected_failures`. Una creación con despacho `error` incrementa tanto
`created` como `error` y no obliga por sí sola a terminar con código 1. Una
respuesta de creación válida para un escenario que debía rechazarse cuenta
como creación y también como fallo inesperado. Los cinco casos inválidos se
añaden a `ORDER_COUNT`: la configuración predeterminada realiza once POST.
La conexión es directa, sin proxy de entorno; los timeouts no son un límite global.

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
verificación de certificados y no recalcula precios históricos. La conexión es
directa, sin proxy de entorno, con `Content-Type` y `Accept` en `application/json`.

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

`script/store_receiver.rb` inicia un proceso Rack/Puma independiente con las
dependencias existentes, sin cargar Rails ni consultar PostgreSQL. Se inicia
desde la raíz con `bundle exec ruby script/store_receiver.rb`
y escucha solo en loopback (`127.0.0.1`). `Ctrl+C`, `SIGINT` o `SIGTERM` lo
detienen esperando las solicitudes en curso; no crea archivos PID ni persiste datos.

| Variable | Valor predeterminado | Valores permitidos |
| --- | --- | --- |
| `STORE_PORT` | `4567` | Entero entre 1 y 65535. |
| `STORE_MODE` | `success` | `success`, `error` o `delay`. |
| `STORE_DELAY_SECONDS` | `6` | Número finito no negativo de segundos; solo se aplica en `delay`. |

Cambiar el puerto requiere ajustar el destino del emisor: los seeds usan 4567.
Es un simulador local sin autenticación, no un receptor de producción. La consola
solo registra restaurante, identificador válido y resultado, nunca cliente,
teléfono, dirección ni payload completo.

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
proceso, con acceso sincronizado; reiniciarlo borra esa memoria. El mismo registro
conserva en memoria los campos recibidos del contrato y la hora de aceptación original
para mostrarlos en `GET /`, sin consultar Rails ni PostgreSQL. Los duplicados no
reemplazan esos datos. La vista usa `Cache-Control: no-store` y horario de Santiago;
no se añade persistencia.

La vista se abre en `http://localhost:4567/` (o el `STORE_PORT` configurado) y
se recarga manualmente con **Actualizar**. Su hora es la de aceptación en el
receptor, en `America/Santiago`, no la de creación en Rails. Una recepción puede
aparecer después de un timeout del emisor: verla aquí no garantiza que Rails
haya recibido la confirmación. La memoria crece con las recepciones y no se
comparte entre procesos.

## Interfaz

El frontend Angular está en un repositorio separado:
<https://github.com/jmanuelbello30/niufoods-orders-ft>. Ya integra login real
contra Rails, listado de órdenes con contadores, detalle en un diálogo,
actualización manual y reintento manual del despacho. No hay creación ni
edición de órdenes en Angular: la creación se realiza por API o Swagger.

En desarrollo se abre en `http://localhost:4200/`; el proxy envía `/api` y sus
rutas anidadas a `http://localhost:3000` sin reescribirlas. Esa configuración
no configura el backend ni el build de producción.

La pestaña conserva token y vencimiento en `sessionStorage`; al recargar valida
la sesión con `GET /api/v1/auth/me`. La expiración no se renueva automáticamente.
El cierre de sesión solicita la revocación remota y borra la sesión local,
avisando si no pudo confirmar la revocación. `sessionStorage` no protege frente
a XSS y cerrar la pestaña no equivale a revocar la sesión persistida en Rails.

El dashboard presenta montos enteros CLP y fechas en `America/Santiago`.
El reintento actualiza el estado según la respuesta, no solo el HTTP 200;
ante un resultado no confirmado exige actualizar el listado con éxito antes
de habilitar otro intento. No hay actualización ni reintentos automáticos.

## Entregables

- Diagramas: pendientes; no hay diagramas incorporados en el repositorio.
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
