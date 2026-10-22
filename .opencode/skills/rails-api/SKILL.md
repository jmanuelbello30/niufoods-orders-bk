---
name: rails-api
description: Implementar y revisar modelos, migraciones, lógica de negocio y endpoints Rails API con PostgreSQL y pruebas Minitest. Usar en cambios del backend; excluye Angular.
---

# Rails API

## Antes de modificar
- Lee AGENTS.md, docs/alcance.md y el código relacionado.
- Implementa únicamente el incremento solicitado.
- El alcance y las reglas del proyecto se consultan en esos archivos; no se redefinen aquí.
- Comprueba las versiones y dependencias existentes antes de introducir cambios.
- Si Ruby no está disponible en PATH, usa ~/.local/bin/mise exec -- seguido del comando.
- No sobrescribas trabajo existente ni generes archivos duplicados.

## Diseño e implementación
- Sigue las convenciones de Rails y utiliza nombres claros.
- Mantén los controladores enfocados en parámetros, coordinación y respuestas HTTP.
- Coloca validaciones e invariantes propias de una entidad en su modelo.
- Para coordinar operaciones entre modelos o integraciones, utiliza clases pequeñas cuando exista una necesidad concreta.
- No agregues capas, repositorios, clases base ni dependencias por anticipación.
- Usa strong params y evita que entradas externas establezcan atributos internos.
- Mantén el contrato JSON y los códigos HTTP definidos en el alcance.
- No conviertas silenciosamente datos inválidos en datos aceptables.

## PostgreSQL y migraciones
- Revisa las migraciones antes de ejecutarlas.
- Utiliza NOT NULL, claves foráneas, índices únicos y CHECK cuando protejan invariantes definidas.
- Complementa validaciones de Rails con restricciones de base de datos cuando corresponda.
- Guarda operaciones que deban ser atómicas dentro de una transacción.
- Ejecuta llamadas HTTP externas después de confirmar la transacción.
- No edites migraciones ya compartidas o aplicadas sin evaluar su estado.
- No ejecutes operaciones destructivas sobre bases existentes o ajenas al proyecto.

## Pruebas con Minitest
- Usa el framework y las herramientas existentes; no agregues RSpec ni otras dependencias sin necesidad.
- Incorpora pruebas junto con cada comportamiento implementado.
- Prueba reglas y resultados observables, evitando copiar la implementación dentro del test.
- Incluye casos válidos, inválidos y límites pertinentes.
- Usa pruebas de modelos para validaciones y reglas de entidad.
- Usa pruebas de integración para contratos HTTP y persistencia observable.
- Comprueba rollback y ausencia de registros parciales cuando la operación sea transaccional.
- En pruebas automatizadas de despacho, sustituye el transporte HTTP para simular éxito, errores y timeout sin depender de servicios reales.
- Mantén datos ficticios y pruebas independientes del orden de ejecución.
- Revisa las fixtures generadas: deben cumplir las restricciones del esquema.
- Ejecuta primero las pruebas afectadas y después la suite existente si el cambio lo justifica.
- No afirmes que una comprobación pasó si no la ejecutaste.

## Revisión y explicación
- Revisa el diff y busca cambios fuera del incremento.
- Informa archivos modificados, propósito, comandos ejecutados y resultados reales.
- Explica brevemente cada regla importante y qué escenario comprueban sus pruebas.
- Distingue errores de código de bloqueos del entorno.
- Indica lo pendiente y detente al completar el incremento.
- No hagas commits ni push.
