---
name: plan-auto
description: Planifica una tarea y ejecútala de corrido sin detenerte a pedir confirmación. Úsala cuando el usuario pida plan automático, plan-auto, o quiera que avances sin interrupciones. No la uses si la tarea es riesgosa o si el usuario quiere revisar el plan antes.
---

# Plan Auto — planificar y ejecutar sin parar

Para tareas que vas a terminar en esta misma sesión.

## No escribas archivo de plan

El plan vive en la sesión. Un documento que nadie va a leer es solo ruido en el repo
y cuota gastada.

Escribes en `docs/ai/tasks/` **solo** si a mitad de camino aparece un relevo: el usuario
lo pide, o un aviso de cuota indica que no vas a llegar. En ese caso usa `relay`.

## 1. Planifica

Antes de tocar código, deja claro en la conversación:

- Objetivo en una línea.
- Archivos que vas a tocar.
- Checklist de 3 a 6 pasos, cada uno terminando en algo verificable.

Si la tarea toca un solo archivo y es obvia, sáltate esto y hazla.

## 2. Ejecuta

Un paso a la vez. Al cerrar cada uno:

1. Ejecuta el comando de verificación de la sección 3 de AGENTS.md.
2. Si falla, arréglalo antes de seguir. No acumules pasos rotos.
3. Commit con un mensaje que diga **qué** cambió y **por qué**.

El commit por paso no es ceremonia: es lo que hace que un corte por cuota te deje
un árbol limpio en vez de un archivo a medias.

## 3. Tests

Si el paso agrega comportamiento, el test se escribe **primero y debe fallar**.
Un test que pasa recién escrito está mal planteado — prueba la implementación,
no el comportamiento.

## 4. Cierra

Reporta lo hecho y el resultado real del comando de verificación.
Si algo quedó fuera o falla, dilo explícitamente. No reportes verde sin haberlo visto.
