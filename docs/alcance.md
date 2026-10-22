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
- Calcular `total_amount` como suma de `quantity * unit_price`.
- `client_total_amount` es opcional y no sustituye nuestro cálculo.
- Guardar orden e ítems en una transacción.
- Despachar después de confirmar esa transacción.
- Un fallo de envío conserva la orden y registra estado `error`.

## Requisitos y decisiones de diseño

- El cálculo y la persistencia del total en el servidor son requisitos de la prueba.
- Recibir y conservar `client_total_amount` es una decisión de diseño; el payload de referencia no incluye ese campo.
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
- Referencias a restaurante o productos inexistentes en el POST invalidan la orden y generan HTTP 422.
- Un fallo de validación no guarda registros parciales ni despacha.
- Los atributos enviados por el cliente no pueden establecer valores internos como `unit_price`, `total_amount` ni `dispatch_status`.
- Queda pendiente decidir si los atributos no permitidos se ignoran o se rechazan.

## Integración

- Despacho síncrono a `dispatch_url`.
- Tienda simulada Ruby con éxito, error y demora.
- Un despacho confirmado cambia `dispatch_status` a `sent`, registra `dispatched_at` y limpia `last_dispatch_error`.
- Un fallo o timeout cambia `dispatch_status` a `error` y conserva la orden.
- Reintento manual sobre la misma orden, utilizando el mismo identificador de orden.
- Receptor reconoce `order_id` para evitar duplicados.
- Órdenes `pending` o `error` pueden reintentarse; órdenes `sent` no.
- La confirmación de recepción no implica preparación ni entrega.
- Los timeouts siguen siendo valores iniciales propuestos: conexión 2 s, lectura 5 s.

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

## Pendiente de aclaración

Definir el comportamiento cuando `client_total_amount` difiera de
`total_amount`. Hasta resolverlo, no se implementará una política de
aceptación, rechazo ni nuevos estados asociados a esa diferencia.
