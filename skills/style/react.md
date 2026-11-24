# Known failures: React reference

Code for the rows of `SKILL.md` §5, for React with shadcn/ui. Adapt the paths. The rule is the same in any stack: the behavior lives in the base component, so every screen gets it, and lint forbids going around it.

## Double submit: the base button waits for its action

Change the library's `Button` itself (for shadcn, `components/ui/button.tsx`), not a wrapper that screens may forget. When `onClick` returns a promise, the button stays disabled until it settles.

```tsx
type ButtonProps = Omit<React.ComponentProps<"button">, "onClick"> & VariantProps<typeof buttonVariants> & {
  asChild?: boolean;
  onClick?: (e: React.MouseEvent<HTMLButtonElement>) => unknown; // may return the action's promise
};

function Button({ onClick, disabled, ...props }: ButtonProps) {
  const [pending, setPending] = React.useState(false);
  const running = React.useRef(false);
  const handle = (e: React.MouseEvent<HTMLButtonElement>) => {
    if (running.current) return e.preventDefault();
    const result = onClick?.(e);
    if (result instanceof Promise) {
      running.current = true;
      setPending(true);
      // The caller shows the error (the mutation's error state); here the button is only released.
      result.catch(() => {}).finally(() => { running.current = false; setPending(false); });
    }
  };
  return <Comp {...props} onClick={handle} disabled={disabled || pending} aria-busy={pending || undefined} />;
}
```

With a data library, a click returns the action's promise: TanStack Query's `mutateAsync`, never `mutate`, which returns nothing and updates its pending flag a tick later, so a double click gets through even with `disabled={isPending}`. In a Next.js app the file needs `"use client"` now that it holds state.

`running` is a ref, not only state: the second click of a double click can arrive before React re-renders the disabled attribute. A form's submit button gets the same guard from the form helper (`isSubmitting`). The API side is idempotent anyway (an operation id with a unique constraint): the button protects the user, the key protects the data.

If the shadcn CLI regenerates the file, the change is lost: keep it in a note at the top of the file and in the project's memory.

## Unbounded input: a default limit

```tsx
function Input({ maxLength = 255, ...props }: React.ComponentProps<"input">) {
  return <input maxLength={maxLength} {...props} />;
}
```

Match the default to the usual text column of the database (255 here), and the same for `Textarea` (the length of a note column, for example 500). A field that really needs more passes its own `maxLength`.

## Draft lost: one hook

```tsx
function useDraft<T>(key: string, initial: T) {
  const [value, setValue] = React.useState<T>(() => {
    try { const raw = sessionStorage.getItem(key); return raw ? (JSON.parse(raw) as T) : initial; } catch { return initial; }
  });
  React.useEffect(() => { sessionStorage.setItem(key, JSON.stringify(value)); }, [key, value]);
  const clear = () => { sessionStorage.removeItem(key); setValue(initial); };
  return [value, setValue, clear] as const;
}
```

Call `clear()` after a successful save and on an explicit "discard".

## Lint: no going around the base components

In the app's code (not in the component library folder):

```js
// eslint.config.mjs
{
  files: ["app/**/*.tsx", "components/**/*.tsx"],
  ignores: ["components/ui/**"],
  rules: {
    "no-alert": "error",
    "no-restricted-syntax": ["error",
      { selector: "JSXAttribute[name.name='onClick'] CallExpression[callee.property.name='mutate']", message: "In a click, return mutateAsync: <Button> waits for it. mutate lets a double click send twice." },
      { selector: "JSXOpeningElement[name.name=/^(input|textarea)$/]:not(:has(JSXAttribute[name.name='maxLength'])):not(:has(JSXAttribute[name.name='type'][value.value=/^(file|hidden|number|checkbox|radio|range|color)$/]))", message: "Text with no limit: use <Input> or <Textarea>, or pass maxLength." },
      { selector: "JSXOpeningElement[name.name='select']", message: "Use the project's select component." },
    ],
  },
}
```

Turning these on in an existing app shows every place that needs the shared component. Fix them in one pass, by class: most `mutate` calls in a click become `mutateAsync` mechanically (an expression body, or the last statement of a block, which then returns it). Keep `mutate` only where a reason is written next to it, such as an idempotent API.
