---
name: plan-review
description: Escribe un plan estructurado en disco y detente a esperar la confirmación del usuario antes de tocar código. Úsala cuando el usuario pida plan-review, un plan para revisar, o quiera aprobar el plan antes de que empieces. También para tareas amplias, riesgosas o que tocan muchos archivos.
---

# Plan Review — plan escrito, con parada obligatoria

Aquí **sí** se escribe archivo: el plan tiene un lector desde el primer segundo, que es
el usuario. Y si después hay relevo, el sucesor ya lo tiene.

## 1. Analiza el impacto

Antes de planificar, averigua qué se ve afectado:

- Busca los puntos de entrada y las dependencias de lo que vas a tocar.
- Si Graphify está disponible (skill `graphify` o su MCP), úsalo para las dependencias:
  vecinos de los archivos objetivo y caminos entre los módulos involucrados.
- Si no está, escribe `no disponible` en ese campo y sigue. **No es motivo para detenerte.**

## 2. Escribe el plan

En `docs/ai/tasks/<slug>.md`, con frontmatter:

```yaml
---
task: <slug>
owner: <tu nombre>
status: IN_PROGRESS
branch: <rama>
updated: <fecha ISO-8601>
---
```

Secciones:

- **Objetivo** — qué y por qué.
- **Archivos** — a modificar, a crear, y dependencias afectadas.
- **Plan** — checklist de 3 a 6 pasos. El último siempre es verificación.
- **Riesgos / no romper** — lo que se puede romper sin que se note.

Concreto y corto. Un plan que el usuario no lee de un vistazo no cumple su función.

## 3. DETENTE

**No modifiques código de la aplicación.** Muestra el plan y espera confirmación explícita.

Si el usuario pide cambios, edita el archivo y vuelve a esperar. No interpretes un
comentario suelto como aprobación.

## 4. Solo tras la confirmación

Ejecuta paso por paso. Al cerrar cada uno: verifica con el comando de la sección 3 de
AGENTS.md, marca `[x]` en el archivo y haz commit.

Si aparece algo que invalida el plan, detente y dilo. No lo replantees por tu cuenta.

Cuando todo esté en `[x]`: `status: DONE`.
