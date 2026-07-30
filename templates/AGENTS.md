# {{PROJECT_NAME}}

> Fuente de verdad para agentes de código. Se lee en cada turno: mantenerlo por debajo
> de ~150 líneas. Si un linter puede imponerlo, no se escribe aquí.

## 1. Qué es
{{PURPOSE}}

<!-- 2-3 líneas: qué problema resuelve y para quién. Sin marketing. -->

## 2. Stack
- **Lenguaje:** {{LANGUAGE}}
- **Framework:** {{FRAMEWORK}}
- **Gestor de paquetes:** {{PACKAGE_MANAGER}}
- **Datos / servicios:** {{SERVICES}}

<!-- El gestor de paquetes es crítico: pnpm y npm no son intercambiables. -->

## 3. Comandos

| Para | Comando |
|---|---|
| Instalar dependencias | `{{CMD_INSTALL}}` |
| Correr en desarrollo | `{{CMD_DEV}}` |
| **Verificar (obligatorio)** | `{{CMD_CHECK}}` |
| Un test puntual | `{{CMD_TEST_ONE}}` |

`{{CMD_CHECK}}` es la única señal de verdad: formato + lint + tipos + tests.
Si falla, el trabajo no está terminado.

## 4. Estructura

```
{{STRUCTURE}}
```

<!-- Solo los directorios que importan y qué va en cada uno. 5-8 líneas. -->

## 5. Convenciones
{{CONVENTIONS}}

<!-- SOLO lo que ningún linter puede imponer: naming, manejo de errores,
     cómo se estructura un test. Si el formateador lo arregla solo, no va aquí. -->

## 6. Reglas de negocio
{{BUSINESS_RULES}}

<!-- Restricciones del dominio que el código no explica por sí solo.
     Ej: "los montos son Decimal, nunca float — SUNAT exige 2 decimales exactos" -->

## 7. No tocar
{{DO_NOT_TOUCH}}

<!-- Archivos generados, migraciones aplicadas, configs de infraestructura. -->

{{ARP_BLOCK}}
