---
name: relay
description: Escribe el handoff de la tarea en curso para que otro agente la retome. Úsala cuando el usuario pida relevar, ceder o pasar la tarea a otro agente, cuando avise que se le está acabando la cuota o los tokens del plan, o cuando un aviso de cuota indique que la sesión no alcanzará a terminar. No la uses si la tarea ya está terminada.
---

# Relay — ceder la tarea a otro agente

Tu única salida es dejar en disco lo que un agente **frío** necesita para continuar.
No sigas trabajando en la tarea después de invocar esto.

## 1. Identifica la tarea

Si existe `.arp/current-plan.md`, **léelo primero**: es el plan que aprobaste en modo
plan, guardado en disco por un hook. Su frontmatter ya trae el `slug` — úsalo tal cual.

Si no existe, el slug va en kebab-case, derivado de la rama actual o del objetivo
(`auth-refactor`, `fix-pdf-export`).

El archivo va en `docs/ai/tasks/<slug>.md`. Si ya existe, actualízalo en vez de crear otro.

## 2. Escribe el archivo

El borrador es materia prima, no producto: no lo copies tal cual. Aporta lo que **solo
tú sabes** y él no puede contener — lo que ya ejecutaste, las decisiones que tomaste
sobre la marcha, las alternativas que descartaste y por qué, dónde te desviaste del plan.
Eso es lo que hace útil al task file.

Usa la plantilla de `docs/ai/tasks/` si existe. Frontmatter:

```yaml
---
task: <slug>
owner: none
status: HANDOFF
branch: <rama actual>
updated: <fecha ISO-8601>
---
```

Contenido obligatorio:

- **Objetivo** — qué se busca y **por qué**. El sucesor necesita la intención, no solo el qué.
- **Archivos** — cuáles tocaste y cuáles faltan.
- **Plan** — el checklist, con `[x]` en lo cerrado y `[ ]` en lo pendiente.
- **Decisiones tomadas** — y **alternativas descartadas con su motivo**. Esto es lo más
  valioso del archivo: evita que el sucesor vuelva a discutir lo ya resuelto.
- **Estado de la verificación** — resultado real del comando de verificación de la
  sección 3 de AGENTS.md. Ejecútalo antes de escribirlo; no lo asumas.
- **Riesgos / no romper.**

Cuando el task file esté escrito, borra `.arp/current-plan.md`. Ya cumplió: el task file
lo reemplaza. Si lo dejas, un corte por cuota posterior lo promovería como si fuera otra
tarea y tendrías dos archivos para lo mismo.

## 3. No escribas lo que git ya dice

Nada de listar diffs, líneas cambiadas ni historial. El sucesor tiene `git diff` y `git log`.
El archivo guarda **intención**, no cambios.

## 4. Deja el árbol limpio

Haz commit de todo, incluido el task file y lo que esté a medias:

```
git add -A && git commit -m "wip(<slug>): handoff — <paso donde quedó>"
```

Es un commit de relevo, con las reglas de la sección 8 de AGENTS.md: entra todo y no
esperas a que la verificación pase. No lo partas en commits atómicos ni invoques la
skill `commit` — aquí el tiempo corre en contra.

Un commit es mucho más difícil de partir a la mitad que un archivo a medio escribir.

## 5. Cierra

Reporta en una línea: ruta del archivo, paso donde quedó, y que el sucesor debe usar
`resume`. No empieces trabajo nuevo.
