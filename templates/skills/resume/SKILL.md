---
name: resume
description: Retoma una tarea que otro agente dejó a medias. Úsala cuando el usuario pida continuar, retomar o seguir una tarea empezada por otro agente, cuando mencione que a Claude o a Codex se le acabaron los tokens, o al abrir un proyecto que tenga tareas pendientes en docs/ai/tasks/.
---

# Resume — retomar una tarea cedida

## 1. Encuentra la tarea

Lee `docs/ai/tasks/*.md`. Busca `status: HANDOFF`.

- Ninguna → dilo y detente. No inventes trabajo.
- Varias → lístalas con su objetivo y pregunta cuál.
- Una con `status: IN_PROGRESS` y `owner` distinto al tuyo → **no la toques**.
  Otro agente puede estar trabajando ahora mismo. Avisa al usuario y espera.

## 2. Reconstruye el estado real

En este orden, antes de escribir una sola línea de código:

1. Lee el task file completo. Es la intención.
2. `git log --oneline -15` y `git diff` — es lo que realmente pasó.
3. Ejecuta el comando de verificación de la sección 3 de AGENTS.md.

El paso 3 no es opcional: el task file dice lo que el predecesor **creía**; el comando
dice lo que **es**. Si difieren, gana el comando.

## 3. Toma posesión

Actualiza el frontmatter antes de trabajar:

```yaml
owner: <tu nombre: claude | codex>
status: IN_PROGRESS
updated: <fecha ISO-8601>
```

## 4. Continúa

Desde la **primera casilla `[ ]`**, no desde el principio.

- No rehagas trabajo ya marcado `[x]` y confirmado por el árbol.
- **No re-litigues las decisiones registradas.** Si una te parece equivocada, dilo al
  usuario en una línea y sigue con ella hasta que él decida lo contrario.
- Respeta la sección de riesgos.

## 5. Cierra cada paso

Al terminar un paso: verifica con el comando, marca `[x]`, actualiza el task file y
haz commit. Puedes ser el siguiente en quedarte sin cuota.

Cuando todo esté en `[x]`: `status: DONE`.
